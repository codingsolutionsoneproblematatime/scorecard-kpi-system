# Scorecard KPI System

A fully automated real-world business intelligence solution built with SQL Server, Excel, and Microsoft 365 tools to track weekly and monthly KPIs (refreshed daily) and department performance for executive decision-making.

## Features

- Pulls data from SQL Server using custom-written SQL queries
- Aggregates metrics from SharePoint-hosted Excel sources
- Captures weekly and monthly snapshots of key performance data
- Tracks department morale via Microsoft Forms surveys
- Integrates data into a structured Excel-based scorecard
- Prepares for Power BI dashboard visualization (in progress)

## Architecture

```text
SQL Server  →  Excel Scorecard Template  →  Power BI (planned)
                 ↑             ↑
           SharePoint      Forms + Automate
```

## Repository Contents
Folder	Description
docs/	Blurred screenshots of the scorecard and morale survey
sql/	Sample SQL queries used to extract KPI data
excel/	A template Excel scorecard with demo data and formulas

## Sample Screenshots
Scorecard Excel Template (Blurred)

Microsoft Forms Morale Survey

## Tools Used
SQL Server & SSMS

Excel with advanced formulas

SharePoint for Excel sync

Microsoft Forms for surveys

Power Automate for data flow

Power BI (dashboard in progress)

## Use Cases
Executive reporting & decision support

Morale monitoring and trend analysis

Weekly department health tracking

Operational performance reviews

## Notes
This repo contains sample data and screenshots only. No sensitive or proprietary client information is included.