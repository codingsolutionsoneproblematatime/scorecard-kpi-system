-- Declare variables
DECLARE @Today DATE = CAST(GETDATE() AS DATE);
DECLARE @StartDate DATE = DATEADD(DAY, 1, EOMONTH(@Today, -13));
DECLARE @EndDate DATE = EOMONTH(@Today, -1);
DECLARE @ReportDate VARCHAR(10) = CONVERT(VARCHAR(10), @EndDate, 101);
DECLARE @StartOfLastMonth DATE = DATEFROMPARTS(YEAR(@Today), MONTH(@Today) - 1, 1);
DECLARE @EndOfLastMonth DATE = EOMONTH(@Today, -1);
DECLARE @MonthEnd DATE = EOMONTH(DATEADD(MONTH, -1, @Today));
DECLARE @PrevMonthEnd DATE = EOMONTH(DATEADD(MONTH, -2, @Today));
DECLARE @StartOfYear DATE = DATEFROMPARTS(YEAR(GETDATE()), 1, 1);

-- CTEs
WITH WIPContracts AS (
    SELECT wip.ContractID
    FROM WIPTotals(CONVERT(varchar(10), GETDATE(), 101)) wip
    LEFT JOIN ProjectsView p ON p.ContractID = wip.ContractID
    WHERE 
        p.ContractStatusID = 2
        AND (ISNULL(wip.OriginalValue, 0) > 0 OR ISNULL(wip.ApprovedChangeOrders, 0) > 0)
        AND p.ProjectNumber <> '00.000'
        AND ISNULL(wip.TotalAmount, 0) < (ISNULL(wip.OriginalValue, 0) + ISNULL(wip.ApprovedChangeOrders, 0))
),
WIPRevenue AS (
    SELECT 
        SUM(
            CASE 
                WHEN a.AccountTypeID = 9 THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
                ELSE 0
            END
        ) AS TotalRevenue
    FROM GLCreditDebit gl
    INNER JOIN WIPContracts w ON gl.GLContractID = w.ContractID
    LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
    WHERE 
        a.AccountTypeID = 9
        AND gl.GLTypeID NOT IN (67, 68, 69)
),
WIPCost AS (
    SELECT 
        SUM(
            CASE 
                WHEN a.AccountTypeID = 5 THEN ISNULL(gl.Debit, 0.0) - ISNULL(gl.Credit, 0.0)
                ELSE 0
            END
        ) AS TotalCost
    FROM GLCreditDebit gl
    INNER JOIN WIPContracts w ON gl.GLContractID = w.ContractID
    LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
    WHERE 
        a.AccountTypeID = 5
        AND gl.GLTypeID NOT IN (67, 68, 69)
),
WIPTimeWithCost AS (
    SELECT 
        dt.ContractID,
        dt.Hours,
        e.Wage,
        dt.Hours * e.Wage AS Cost
    FROM DailyTimeView dt
    INNER JOIN EmployeesView e ON dt.EmployeeID = e.EmployeeID
    WHERE dt.ContractID IN (SELECT ContractID FROM WIPContracts)
      AND ISNULL(e.TempHire, 0) <> 1
      AND ISNULL(e.Wage, 0) > 0
),
YTDRevenue AS (
    SELECT 
        SUM(
            CASE 
                WHEN a.AccountTypeID = 9 THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
                ELSE 0
            END
        ) AS TotalRevenue
    FROM GLCreditDebit gl
    LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
    WHERE 
        a.AccountTypeID = 9
        AND gl.GLTypeID NOT IN (67, 68, 69)
        AND gl.TranDate BETWEEN @StartOfYear AND @Today
),
YTDCogs AS (
    SELECT 
        SUM(
            CASE 
                WHEN a.AccountTypeID = 5 THEN ISNULL(gl.Debit, 0.0) - ISNULL(gl.Credit, 0.0)
                ELSE 0
            END
        ) AS TotalCost
    FROM GLCreditDebit gl
    LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
    WHERE 
        a.AccountTypeID = 5
        AND gl.GLTypeID NOT IN (67, 68, 69)
        AND gl.TranDate BETWEEN @StartOfYear AND @Today
),
BudgetedHours AS (
    SELECT ct.ContractID, SUM(ISNULL(ct.Quantity, 0)) AS BudgetedHours
    FROM ContractTasks ct
    WHERE ct.ContractID IN (SELECT ContractID FROM WIPContracts)
    GROUP BY ct.ContractID
),
ActualHours AS (
    SELECT dt.ContractID, SUM(ISNULL(dt.Total, 0)) AS ActualHours
    FROM DailyTimeView dt
    WHERE dt.ContractID IN (SELECT ContractID FROM WIPContracts)
    GROUP BY dt.ContractID
),
CombinedManHours AS (
    SELECT
        SUM(ISNULL(bh.BudgetedHours, 0)) AS TotalBudgetedHours,
        SUM(ISNULL(ah.ActualHours, 0)) AS TotalActualHours
    FROM WIPContracts w
    INNER JOIN BudgetedHours bh ON w.ContractID = bh.ContractID
    LEFT JOIN ActualHours ah ON bh.ContractID = ah.ContractID
    WHERE ISNULL(bh.BudgetedHours, 0) > 0
),
InvoicePairs AS (
    SELECT 
        TransDocID,
        MAX(CASE WHEN GLTypeName = 'PAYAPP' THEN TranDate END) AS InvoiceDate,
        MAX(CASE WHEN GLTypeName = 'PAYAPP-PMT' THEN TranDate END) AS PaymentDate
    FROM ARInquiryView
    WHERE GLTypeName IN ('PAYAPP', 'PAYAPP-PMT')
    GROUP BY TransDocID
    HAVING 
        MAX(CASE WHEN GLTypeName = 'PAYAPP' THEN TranDate END) IS NOT NULL AND
        MAX(CASE WHEN GLTypeName = 'PAYAPP-PMT' THEN TranDate END) IS NOT NULL
),
DaysToPay AS (
    SELECT 
        DATEDIFF(DAY, InvoiceDate, PaymentDate) AS DaysDiff,
        InvoiceDate
    FROM InvoicePairs
    WHERE PaymentDate > InvoiceDate
),
WIPBudgetLabor AS (
    SELECT 
        SUM(ISNULL(ct.Amount, 0)) AS TotalBudgetLaborForWIP
    FROM ContractTasks ct
    WHERE ct.ContractID IN (SELECT ContractID FROM WIPContracts)
),
BudgetLaborWithWIP AS (
    SELECT ct.ContractID, SUM(ISNULL(ct.Amount, 0)) AS BudgetLabor
    FROM ContractTasks ct
    WHERE ct.ContractID IN (SELECT ContractID FROM WIPContracts)
    GROUP BY ct.ContractID
    HAVING SUM(ISNULL(ct.Amount, 0)) > 0
),
ActualHoursWithBudgetLabor AS (
    SELECT dt.ContractID, SUM(ISNULL(dt.Total, 0)) AS ActualHours
    FROM DailyTimeView dt
    WHERE dt.ContractID IN (SELECT ContractID FROM BudgetLaborWithWIP)
    GROUP BY dt.ContractID
),
TotalActualHoursWithBudgetLabor AS (
    SELECT SUM(ActualHours) AS TotalActualHoursForProjectsWithBudgetedLabor
    FROM ActualHoursWithBudgetLabor
),
InStaffHours AS ( 
    SELECT 
        dt.ContractID,
        SUM(DATEDIFF(MINUTE, dt.InTime, dt.OutTime) / 60.0) AS InStaffTotalHours
    FROM DailyTimeView dt
    INNER JOIN EmployeesView e ON dt.EmployeeID = e.EmployeeID
    WHERE 
        ISNULL(e.TempHire, 0) <> 1
        AND ISNULL(e.Wage, 0) > 0
        AND dt.ContractID IS NOT NULL
        AND dt.InTime BETWEEN @StartOfYear AND @Today
    GROUP BY dt.ContractID
),
ProjectLevel AS (
    SELECT 
        gl.GLContractID AS ContractID,
        SUM(CASE WHEN a.AccountTypeID = 9 THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0) ELSE 0 END) AS TotalRevenueYTD,
        SUM(CASE WHEN gl.AccountID = '19F9CDB3-A958-4E94-9FAC-FA503C120C48' THEN ISNULL(gl.Debit, 0.0) - ISNULL(gl.Credit, 0.0) ELSE 0 END) AS InStaffLaborYTD,
        SUM(CASE WHEN a.AccountTypeID = 5 THEN ISNULL(gl.Debit, 0.0) - ISNULL(gl.Credit, 0.0) ELSE 0 END) AS TotalCOGSYTD,
        ISNULL(hrs.InStaffTotalHours, 0) AS InStaffHoursYTD
    FROM GLCreditDebit gl
    LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
    LEFT JOIN InStaffHours hrs ON gl.GLContractID = hrs.ContractID
    WHERE 
        a.AccountTypeID IN (5, 9)
        AND gl.GLTypeID NOT IN (67, 68, 69)
        AND gl.TranDate BETWEEN @StartOfYear AND @Today
    GROUP BY gl.GLContractID, hrs.InStaffTotalHours
    HAVING 
        SUM(CASE WHEN a.AccountTypeID = 9 THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0) ELSE 0 END) > 0
        AND SUM(CASE WHEN gl.AccountID = '19F9CDB3-A958-4E94-9FAC-FA503C120C48' THEN ISNULL(gl.Debit, 0.0) - ISNULL(gl.Credit, 0.0) ELSE 0 END) > 0
        AND ISNULL(hrs.InStaffTotalHours, 0) > 0
)

-- Final Output
SELECT 'Pipeline', CAST(SUM(ISNULL(wip.OriginalValue, 0) + ISNULL(wip.ApprovedChangeOrders, 0) - ISNULL(wip.TotalAmount, 0)) AS DECIMAL(18, 2)) FROM WIPTotals(CONVERT(varchar(10), GETDATE(), 101)) wip
LEFT JOIN ProjectsView p ON p.ContractID = wip.ContractID
WHERE p.ContractStatusID = 2 AND (wip.OriginalValue > 0 OR wip.ApprovedChangeOrders > 0) AND p.ProjectNumber <> '00.000'

UNION ALL

SELECT 'AvgMonthlyIDCSpendLast12CompleteMonths', CAST(SUM(gl.TranAmount) / 12.0 AS DECIMAL(18, 2))
FROM GL gl
INNER JOIN CostCodes cc ON cc.CostCodeID = gl.CostCodeID
WHERE gl.TranDate >= DATEADD(MONTH, -12, DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1))
  AND gl.TranDate <= EOMONTH(DATEADD(MONTH, -1, @Today))
  AND cc.Number LIKE '9%'
  AND gl.GLTypeID IN (2, 7, 8, 12, 17, 18, 19, 44, 45)

UNION ALL

SELECT 'AvgMonthlyCOGSSpendLast12CompleteMonths',
       CAST((SUM(IIF(a.AccountTypeID = 5, ISNULL(gl.Debit, 0.0) - ISNULL(gl.Credit, 0.0), ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)))) / 12.0 AS DECIMAL(18, 2))
FROM GLCreditDebit gl
LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
WHERE a.AccountTypeID = 5
  AND NOT gl.GLTypeID IN (67, 68, 69)
  AND gl.TranDate BETWEEN @StartDate AND @EndDate

UNION ALL

SELECT 'CashBalanceAsOfEOM', SUM(ROUND(ISNULL(gl.Debit, 0.0) - ISNULL(gl.Credit, 0.0), 2))
FROM GLCreditDebit gl
LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
WHERE gl.TranDate <= @EndOfLastMonth AND a.IsAsset = 1 AND a.AccountTypeID IN (3, 0, 1)

UNION ALL

SELECT 'TotalBudgetForOpenWIPProjectsAsOfEOM', CAST(SUM(b.amount) AS DECIMAL(18, 2))
FROM budgetitemsview b
WHERE b.ContractID IN (
    SELECT wip.ContractID
    FROM WIPTotals(@ReportDate) wip
    LEFT JOIN ProjectsView p ON p.ContractID = wip.ContractID
    WHERE p.ContractStatusID = 2
      AND (ISNULL(wip.OriginalValue, 0) > 0 OR ISNULL(wip.ApprovedChangeOrders, 0) > 0)
      AND p.ProjectNumber <> '00.000'
      AND ISNULL(wip.TotalAmount, 0) < (ISNULL(wip.OriginalValue, 0) + ISNULL(wip.ApprovedChangeOrders, 0))
)

UNION ALL

SELECT 'NetIncomeLastCompletedMonth', CAST(SUM(
           CASE a.AccountTypeID
               WHEN 9 THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
               WHEN 5 THEN -1 * (ISNULL(gl.Debit, 0.0) - ISNULL(gl.Credit, 0.0))
               WHEN 7 THEN -1 * (ISNULL(gl.Debit, 0.0) - ISNULL(gl.Credit, 0.0))
               WHEN 12 THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
               ELSE 0
           END) AS DECIMAL(18, 2))
FROM GLCreditDebit gl
LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
WHERE a.AccountTypeID IN (5, 7, 9, 12) AND gl.GLTypeID NOT IN (67, 68, 69) AND gl.TranDate BETWEEN @StartOfLastMonth AND @EndOfLastMonth

UNION ALL

SELECT 'AR_MoM_Delta_LastCompletedMonth', ROUND(PrevBal - CurrBal, 2)
FROM (
    SELECT
        (SELECT SUM(ROUND(ISNULL(gl.Debit, 0.0) - ISNULL(gl.Credit, 0.0), 2))
         FROM GLCreditDebit gl
         LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
         WHERE a.IsAsset = 1 AND a.AccountTypeID = 2 AND gl.TranDate <= @MonthEnd) AS CurrBal,
        (SELECT SUM(ROUND(ISNULL(gl.Debit, 0.0) - ISNULL(gl.Credit, 0.0), 2))
         FROM GLCreditDebit gl
         LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
         WHERE a.IsAsset = 1 AND a.AccountTypeID = 2 AND gl.TranDate <= @PrevMonthEnd) AS PrevBal
) t

UNION ALL

SELECT 'WIPTotalBudgetedHours', TotalBudgetedHours FROM CombinedManHours
UNION ALL
SELECT 'WIPTotalActualHours', TotalActualHours FROM CombinedManHours
UNION ALL
SELECT 'WIPActualHoursToBudgetedHoursRatio',
       CASE 
           WHEN TotalBudgetedHours = 0 THEN NULL 
           ELSE ROUND(TotalActualHours / TotalBudgetedHours, 2) 
       END
FROM CombinedManHours

UNION ALL

SELECT 'WIPSumRevisedContractValues', SUM(ISNULL(wip.OriginalValue, 0) + ISNULL(wip.ApprovedChangeOrders, 0))
FROM WIPTotals(CONVERT(VARCHAR(10), EOMONTH(DATEADD(MONTH, -1, GETDATE())), 101)) wip
LEFT JOIN ProjectsView p ON p.ContractID = wip.ContractID
WHERE p.ContractStatusID = 2 AND (wip.OriginalValue > 0 OR wip.ApprovedChangeOrders > 0) AND p.ProjectNumber <> '00.000' AND ISNULL(wip.TotalAmount, 0) < (ISNULL(wip.OriginalValue, 0) + ISNULL(wip.ApprovedChangeOrders, 0))

UNION ALL

SELECT 'TotalIncomeLastCompletedMonth', SUM(q.Total)
FROM AccountsView a
LEFT JOIN (
    SELECT gl.AccountID,
           SUM(IIF(a.AccountTypeID IN (7, 11, 5), ISNULL(gl.Debit, 0.0) - ISNULL(gl.Credit, 0.0), ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0))) AS Total
    FROM GLCreditDebit gl
    LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
    WHERE a.AccountTypeID IN (5, 7, 9, 11, 12) AND gl.GLTypeID NOT IN (67, 68, 69) AND gl.TranDate BETWEEN @StartOfLastMonth AND @EndOfLastMonth
    GROUP BY gl.AccountID
) q ON q.AccountID = a.AccountID
WHERE a.AccountTypeDescription = 'Income'

UNION ALL

SELECT 'NetOrdinaryIncomeLastCompletedMonth',
       SUM(CASE a.AccountTypeDescription WHEN 'Income' THEN q.Total WHEN 'Cost of Goods Sold' THEN -1 * q.Total WHEN 'Expense' THEN -1 * q.Total ELSE 0 END)
FROM AccountsView a
LEFT JOIN (
    SELECT gl.AccountID,
           SUM(IIF(a.AccountTypeID IN (5, 7, 11), ISNULL(gl.Debit, 0.0) - ISNULL(gl.Credit, 0.0), ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0))) AS Total
    FROM GLCreditDebit gl
    LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
    WHERE a.AccountTypeID IN (5, 7, 9, 11, 12) AND gl.GLTypeID NOT IN (67, 68, 69) AND gl.TranDate BETWEEN @StartOfLastMonth AND @EndOfLastMonth
    GROUP BY gl.AccountID
) q ON q.AccountID = a.AccountID
WHERE a.AccountTypeDescription IN ('Income', 'Cost of Goods Sold', 'Expense')

UNION ALL

SELECT 'ARAgingReportUnbilledRetainage', SUM(r.UnpaidRetainage)
FROM ARAgingSummary(CAST(GETDATE() AS DATE), CAST(GETDATE() AS DATE)) r
LEFT JOIN ProjectsView pv ON pv.ContractID = r.ContractID

UNION ALL

SELECT 'ARAvgDaysToPayLast30Days', ROUND(AVG(CAST(DaysDiff AS FLOAT)), 0)
FROM DaysToPay
WHERE InvoiceDate >= DATEADD(DAY, -30, GETDATE())

UNION ALL

SELECT 'ARAvgDaysToPayLast60Days', ROUND(AVG(CAST(DaysDiff AS FLOAT)), 0)
FROM DaysToPay
WHERE InvoiceDate >= DATEADD(DAY, -60, GETDATE())

UNION ALL

SELECT 'ARAvgDaysToPayLast90Days', ROUND(AVG(CAST(DaysDiff AS FLOAT)), 0)
FROM DaysToPay
WHERE InvoiceDate >= DATEADD(DAY, -90, GETDATE())

UNION ALL

SELECT 'ARAvgDaysToPayLast180Days', ROUND(AVG(CAST(DaysDiff AS FLOAT)), 0)
FROM DaysToPay
WHERE InvoiceDate >= DATEADD(DAY, -180, GETDATE())

UNION ALL

SELECT 'ARAvgDaysToPayLast365Days', ROUND(AVG(CAST(DaysDiff AS FLOAT)), 0)
FROM DaysToPay
WHERE InvoiceDate >= DATEADD(DAY, -365, GETDATE())

UNION ALL

SELECT 'ARAvgDaysToPaySinceDawnOfTime', ROUND(AVG(CAST(DaysDiff AS FLOAT)), 0)
FROM DaysToPay

UNION ALL

-- AP MoM Delta for Last Completed Month
SELECT 
    'AP_MoM_Delta_LastCompletedMonth',
    ROUND(
        ISNULL((
            SELECT SUM(ROUND(ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0), 2))
            FROM GLCreditDebit gl
            LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
            WHERE gl.TranDate <= @MonthEnd
              AND a.IsLiability = 1
              AND (
                  a.AccountTypeDescription IN ('Accounts Payable', 'Credit Card Account')
                  OR a.AccountCodeName = '20700 Overbillings'
              )
        ), 0)
        -
        ISNULL((
            SELECT SUM(ROUND(ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0), 2))
            FROM GLCreditDebit gl
            LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
            WHERE gl.TranDate <= @PrevMonthEnd
              AND a.IsLiability = 1
              AND (
                  a.AccountTypeDescription IN ('Accounts Payable', 'Credit Card Account')
                  OR a.AccountCodeName = '20700 Overbillings'
              )
        ), 0)
    , 2)

UNION ALL

SELECT 'TotalCurrentLiabilitiesAsOfEOM', SUM(ROUND(ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0), 2))
FROM GLCreditDebit gl
LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
WHERE 
  a.IsLiability = 1
  AND a.AccountTypeID != 10  -- Exclude long-term liabilities
  AND gl.TranDate <= @MonthEnd

UNION ALL

SELECT 
  'ARAvgDaysOutstanding' AS Metric,
  ROUND(AVG(CAST(DATEDIFF(DAY, ai.TranDate, GETDATE()) AS FLOAT)), 0) AS Value
FROM dbo.ARInquiryView ai
WHERE 
  --ai.GLTypeName = 'PAYAPP'  -- Invoice transaction
  ai.BalanceDue > 1      -- Still unpaid (partially or fully)
  AND ai.TranDate IS NOT NULL
  AND ai.Project IS NOT NULL

UNION ALL

SELECT 
    'Outstanding AR (0-30 days old)' AS Metric,
    SUM(ai.BalanceDue) AS Amount
FROM dbo.ARInquiryView ai
WHERE ai.BalanceDue > 1
  AND ai.TranDate IS NOT NULL
  AND ai.Project IS NOT NULL
  AND DATEDIFF(DAY, ai.TranDate, GETDATE()) BETWEEN 0 AND 30

UNION ALL

SELECT 
    'Outstanding AR (31-60 days old)' AS Metric,
    SUM(ai.BalanceDue) AS Amount
FROM dbo.ARInquiryView ai
WHERE ai.BalanceDue > 1
  AND ai.TranDate IS NOT NULL
  AND ai.Project IS NOT NULL
  AND DATEDIFF(DAY, ai.TranDate, GETDATE()) BETWEEN 31 AND 60

UNION ALL

SELECT 
    'Outstanding AR (61-90 days old)' AS Metric,
    SUM(ai.BalanceDue) AS Amount
FROM dbo.ARInquiryView ai
WHERE ai.BalanceDue > 1
  AND ai.TranDate IS NOT NULL
  AND ai.Project IS NOT NULL
  AND DATEDIFF(DAY, ai.TranDate, GETDATE()) BETWEEN 61 AND 90

UNION ALL

SELECT 
    'Outstanding AR (91-180 days old)' AS Metric,
    SUM(ai.BalanceDue) AS Amount
FROM dbo.ARInquiryView ai
WHERE ai.BalanceDue > 1
  AND ai.TranDate IS NOT NULL
  AND ai.Project IS NOT NULL
  AND DATEDIFF(DAY, ai.TranDate, GETDATE()) BETWEEN 91 AND 180

UNION ALL

SELECT 
    'Outstanding AR (181-365+ days old)' AS Metric,
    SUM(ai.BalanceDue) AS Amount
FROM dbo.ARInquiryView ai
WHERE ai.BalanceDue > 1
  AND ai.TranDate IS NOT NULL
  AND ai.Project IS NOT NULL
  AND DATEDIFF(DAY, ai.TranDate, GETDATE()) >= 181

UNION ALL

SELECT 'WIPTotalBudgetedLabor', TotalBudgetLaborForWIP FROM WIPBudgetLabor

UNION ALL

SELECT 'TotalActualHoursForProjectsWithBudgetedLabor', TotalActualHoursForProjectsWithBudgetedLabor
FROM TotalActualHoursWithBudgetLabor

UNION ALL

SELECT 
    'WIP_GM_Percent' AS Metric,
    CAST(
        CASE 
            WHEN ISNULL(r.TotalRevenue, 0) = 0 THEN NULL
            ELSE ROUND((ISNULL(r.TotalRevenue, 0) - ISNULL(c.TotalCost, 0)) * 1.0 / ISNULL(r.TotalRevenue, 0), 4)
        END AS DECIMAL(10, 4)
    ) AS Value
FROM WIPRevenue r
CROSS JOIN WIPCost c

UNION ALL

SELECT 'YTD_GM_Percent' AS Metric,
       CAST(CASE 
           WHEN ISNULL(r.TotalRevenue, 0) = 0 THEN NULL
           ELSE ROUND((ISNULL(r.TotalRevenue, 0) - ISNULL(c.TotalCost, 0)) * 1.0 / ISNULL(r.TotalRevenue, 0), 4)
       END AS DECIMAL(10, 4)) AS Value
FROM YTDRevenue r
CROSS JOIN YTDCogs c

UNION ALL

-- Calculate Net Profit % YTD
SELECT 'NetProfitPercentYTD' AS Metric,
    -- Net Profit as % of Income
    CASE 
        WHEN SUM(CASE WHEN a.AccountTypeDescription = 'Income'
                      THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
                      ELSE 0 END) = 0 THEN NULL
        ELSE 
            ROUND(
                SUM(
                    CASE 
                        WHEN a.AccountTypeDescription = 'Income'
                            THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
                        WHEN a.AccountTypeDescription = 'Cost of Goods Sold'
                            THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
                        WHEN a.AccountTypeDescription = 'Expense'
                            THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
                        WHEN a.AccountTypeDescription = 'Other Income'
                            THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
                        ELSE 0
                    END
                ) * 1.0
                /
                NULLIF(
                    SUM(CASE WHEN a.AccountTypeDescription = 'Income'
                             THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
                             ELSE 0 END),
                    0
                )
            , 4)
    END

FROM GLCreditDebit gl
LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
WHERE 
    a.AccountTypeDescription IN ('Income', 'Cost of Goods Sold', 'Expense', 'Other Income')
    AND gl.GLTypeID NOT IN (67, 68, 69)
    AND gl.TranDate BETWEEN @StartOfYear AND @Today

UNION ALL

SELECT 'InStaffLaborHourlyRateYTD' AS Metric,
    ROUND(
        (SUM(InStaffLaborYTD) * 1.0 / NULLIF(SUM(TotalCOGSYTD), 0)) * SUM(TotalRevenueYTD) / NULLIF(SUM(InStaffHoursYTD), 0),
        2
    )
FROM ProjectLevel

UNION ALL

-- Calculate Gross Profit % YTD
SELECT 'GrossProfitPercentYTD' AS Metric,
    -- Gross Profit as % of Income
    CASE 
        WHEN SUM(CASE WHEN a.AccountTypeDescription = 'Income'
                      THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
                      ELSE 0 END) = 0 THEN NULL
        ELSE 
            ROUND(
                SUM(
                    CASE 
                        WHEN a.AccountTypeDescription = 'Income'
                            THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
                        WHEN a.AccountTypeDescription = 'Cost of Goods Sold'
                            THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
--                      WHEN a.AccountTypeDescription = 'Expense'
--                          THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
--                      WHEN a.AccountTypeDescription = 'Other Income'
--                          THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
                        ELSE 0
                    END
                ) * 1.0
                /
                NULLIF(
                    SUM(CASE WHEN a.AccountTypeDescription = 'Income'
                             THEN ISNULL(gl.Credit, 0.0) - ISNULL(gl.Debit, 0.0)
                             ELSE 0 END),
                    0
                )
            , 4)
    END

FROM GLCreditDebit gl
LEFT JOIN AccountsView a ON a.AccountID = gl.AccountID
WHERE 
    a.AccountTypeDescription IN ('Income', 'Cost of Goods Sold')
    AND gl.GLTypeID NOT IN (67, 68, 69)
    AND gl.TranDate BETWEEN @StartOfYear AND @Today

UNION ALL

SELECT 'InStaffLaborEfficiencyWIP' AS Metric,
    CASE 
        WHEN SUM(t.Hours) = 0 THEN NULL
        ELSE ROUND(SUM(t.Cost) / SUM(t.Hours), 2)
    END
FROM WIPTimeWithCost t