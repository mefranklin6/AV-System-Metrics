# AV-System-Metrics

A standardized collection of systems to gather metric and usage data from commercial AV control systems and related devices.

This system replaces and expands upon my previous project: [Extron Database Connector](https://github.com/mefranklin6/ExtronDatabaseConnector)

## Overview

![main overview](/images/main_overview.png)

Control processors send data to a server (or serverless cloud function) which inserts metric data into a database.

## Setup

1. Choose a hosting option below. Follow the readme file in the corresponding folder for detailed setup instructions.
2. Incorporate the appropriate client code/driver/module into your existing control system, or see the included [Developer Guide](/Clients/Developer%20Guide/README.md) for making your own if your system is not included yet (please consider contributing!)

## Hosting Options

There are currently two hosting systems that will support any AV controller or device that can send REST requests, which should be almost all commercial AV control systems.

- [Serverless cloud-native implementation in AWS using Lambda and DynamoDB](/AWS_Serverless/README.md)

- [Self-Hosted Docker Compose system using Go and PostgreSQL](/Self_Hosted/README.md)

## Current Supported Clients

### Fully tested and validated

- [Extron Control Script](/Clients/Extron%20ECS/metrics_client.py)
- [Generic Python 3 Module](/Clients/Extron%20ECS/metrics_client.py) (simply run the ECS module on a workstation)

### AI-written and not yet tested

- [Crestron C# Client](/Clients/Crestron_AI_Generated/README.md)
- [AMX MUSE Python Client](/Clients/AMX_AI_Generated/README.md)
- [QSC Q-SYS Lua Client](/Clients/QSC_AI_Generated/README.md)

Coming Soon: Extron Global Configurator Plus/Pro (if they make my driver!)

Don't see your system here? Consider making one with the included [Developer Guide](/Clients/Developer%20Guide/README.md)

Tried one of the AI-written clients? Please provide feedback on your experience, any issues encountered, and any improvements that could be made. This will help in validating and refining these clients for broader use.

## Result

After initial setup and deployment, you will end up with a database containing usage and metric data as such: ![database_schema](/images/db_schema.png)

You can then analyze the data with scripts or visualize it in tools like PowerBI ![power_bi_example](/images/power_bi_example.png)

## Contributions encouraged

The goal of this project is to provide a solution for every major AV control system, with a variety of hosting options. I only have access to a limited number of proprietary control systems and only have experience with a limited number of cloud providers, so contributions are highly encouraged!
