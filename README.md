# AV-System-Metrics

A standardized collection of systems to gather metric and usage data from commercial AV control systems and related devices.

This system replaces and expands upon my previous project: [Extron Database Connector](https://github.com/mefranklin6/ExtronDatabaseConnector)

## Reason

This system is for you if you've ever been asked:

- "How often is the camera actually used in this room?",
- "Can we get rid of this input device?",
- "When was the system last turned off?",
- "Has anyone ever pressed this button?"

Granular usage and metric data from your AV control systems and related devices, providing insights into how the systems are actually being used and helping inform decisions about system management, optimization and UX design.

## Overview

![main overview](/images/main_overview.png)

Control processors send data to a server (or serverless cloud function) which inserts metric data into a database.

## Setup

1. Choose a hosting option below. Follow the readme file in the corresponding folder for detailed setup instructions.
2. Incorporate the appropriate client code/driver/module into your existing control system. See the Supported Clients section below and follow the readme documents.

## Hosting Options

There are currently two hosting systems that will support any AV controller or device that can send REST requests, which should be almost all commercial AV control systems.

- [Serverless cloud-native implementation in AWS using Lambda and DynamoDB](/AWS_Serverless/README.md)

- [Self-Hosted Docker Compose system using Go and PostgreSQL](/Self_Hosted/README.md)

## Supported Clients

### Fully tested and validated

- [Extron Control Script Python](/Clients/Extron%20ECS/README.md)
- [Generic Python 3](/Clients/Extron%20ECS/README.md) (simply run the ECS module on a workstation)

### AI-written and not yet tested (Testers Needed!)

- [Crestron C#](/Clients/Crestron_AI_Generated/README.md)
- [AMX MUSE Python](/Clients/AMX_AI_Generated/README.md) (Pure Python implementation tested working on a workstation)
- [QSC Q-SYS Lua](/Clients/QSC_AI_Generated/README.md)

### Build your own

Don't see your system here? Consider making one with the included [Developer Guide](/Clients/Developer%20Guide/README.md)

### Future Support

- Extron Global Configurator Plus/Pro if Extron agrees. I want to really fine tune the system before I ask them to port it to a GCP driver.

Tried one of the AI-written clients? Please provide feedback on your experience, any issues encountered, and any improvements that could be made. This will help in validating and refining these clients for broader use.

## Result

After initial setup and deployment, you will end up with a database containing usage and metric data as such: ![database_schema](/images/db_schema.png)

You can then analyze the data with scripts or visualize it in tools like PowerBI. The self-hosted PostgreSQL deployment can also publish a database port for pgAdmin or similar tools when explicitly enabled in its `.env` file. ![power_bi_example](/images/power_bi_example.png)

## Contributions encouraged

The goal of this project is to provide a solution for every major AV control system, with a variety of hosting options. I only have access to a limited number of proprietary control systems and only have experience with a limited number of cloud providers, so contributions are highly encouraged!
