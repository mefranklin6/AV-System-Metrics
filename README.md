# AV-System-Metrics

A universal system to collect metric and usage data from commercial AV control systems and others.

This system replaces and expands upon my previous project, [Extron Database Connector](https://github.com/mefranklin6/ExtronDatabaseConnector)

## Hosting Options

There are currently two hosting systems that will support any AV controller that can send REST requests, which should be almost all commercial AV control systems.

- [Serverless cloud-native implementation in AWS using Lambda and DynamoDB](/AWS_Serverless/README.md)

- [Self-Hosted Docker Compose system using Go and PostgreSQL](/Self_Hosted/README.md)

## Current Supported Clients

- [Extron Control Script](/Clients/Extron%20ECS/metrics_client.py)
- [Generic Python 3 Module](/Clients/Extron%20ECS/metrics_client.py) (simply run the ECS module on a workstation)
- Coming Soon: Extron Global Configurator Plus/Pro (if they make my driver)


## Contributions encouraged

I only have access to a limited number of proprietary control systems, so it would be great to have at least one solution to all the major players in the space. Please consider sending a pull request if you make one!
