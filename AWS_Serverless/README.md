# AV-System-Metrics: AWS Serverless

AWS Serverless system using Lambda and DynamoDB for AV system metric ingestion.

- Client: Any control system that can sent REST web requests
- Server: Amazon Web Services Serverless (Lambda, DynamoDB)

## Costs

This system may be covered partially or entirely by the AWS "Always Free" tier for most organizations! Make sure to monitor, setup budgets, alerts, handle logging, and consult with your rep or admin to be sure for your use case.

## How To

This guide presumes you already have an AWS admin account setup with the appropriate permissions.

### Create the Database

- Make sure your AWS admin console is in the region you want to use
![AWS Region Select](images/image.png)
- DynamoDB -> Tables -> Create Table:
  - Partition key: `clientname` : string
  - Sort key: `sk` : string
  - Table Settings: Customize Settings
  
  *Note, the 'best' way to setup the DB is to keep "On-demand" default settings as that benefits from true serverless architecture, but the safest way to make sure you stay within alway-free or to keep costs minimal is to set the below. Keep in mind data will be lost if your reads/writes exceed the capacity of one unit*
  - Read/write capacity settings
    - Provisioned
    - Read and Write Auto Scaling to Off
    - Read and Write Provisioned capacity units to 1

![alt text](images/image-5.png)

### Create the Lambda Function

Lambda -> Functions -> Create Function:

- Author from scratch
- Runtime: Python (latest supported version)
- Additional Settings
  - Check `ARM64 architecture`
  - Check `Function URL`
    - Set Auth type to `NONE` (we handle IAM in the function)

Leave the rest of the values at default

### Create environmental variables

![Code Editor Env Variables](images/image-3.png)
![Env Var Editor](images/image-2.png)

`ALLOWED_NET_CIDR`: Optional CIDR network notation of what client IP's are allowed communicate with the function. It is recommended you set this to only the public IP(s) of your network. Example: 132.241.50.0/24 (covers 132.241.50.0 - 132.241.50.255). If you're using NAT and only have one public IP that all your devices communicate from, use `your_address/32`. If no address is specified any IP can call the function, but they'll still need the bearer token to perform any actions.

`BEARER_TOKEN`: Generate your own random alphanumeric string. Keep this a secret. This is your client authentication and is required before the function will write anything to the database.

`TABLE_NAME`: The name of the database table you made earlier.

### Copy the code

Copy `/server/metrics_aws_lambda.py` into your Lambda code editor and click deploy.

### Grant Database Write Access to the Lambda Function

- Lambda → your-function → Configuration → Permissions → Execution role
- Click on the role name (my-function-role-abc123)
- Click `Add permissions` -> `Create inline policy`
- Open the JSON editor and paste the below JSON, replacing the `variables` as needed, then save the policy.

Replace:

- `REGION` → e.g. us-west-1
- `ACCOUNT_ID` → your AWS account ID (find in the very top right of the webpage)
- `TABLE_NAME` → your DynamoDB table name

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem",
        "dynamodb:BatchWriteItem"
      ],
      "Resource": "arn:aws:dynamodb:<REGION>:<ACCOUNT_ID>:table/<>TABLE_NAME"
    }
  ]
}

```

### Do a quick test in Powershell

Give it a minute or two for resources to deploy and permissions to update, then, from a workstation within the allowed IP range (if specified):

```pwsh
Invoke-RestMethod -Method POST -Uri "<your_function_uri>" `
>>   -ContentType "application/json" `
>>   -Headers @{Authorization = 'Bearer <your bearer token>'} `
>>   -Body '{
>>     "clientname": "test-client",
>>     "timestamp": "2026-05-12T10:27:35.442913",
>>     "metric": "i_am_testing",
>>     "action": "test_executed"
>>   }'
```

If configured correctly, you should see:

```pwsh
  ok count
  -- -----
True     1
```

### Check your table for the test entry

DynamoDB -> Tables -> `your table` > Explore Items

![explore database](images/image-4.png)

### Recommended: Set Log Rotation

The Lambda function is coded to only log warnings and errors, but simply invoking the function creates four log entries from Amazon by default. In order to be safe, it is recommended to set a log rotation schedule if your internal policies allow.

CloudWatch -> Log Management
![log rotation](images/image-6.png)

## Troubleshooting

If your test is getting errors, find the actual cause in the live logs:
CloudWatch -> Logs -> Live Tail -> Select your function in the filter dropdown -> Apply filters

Then you can send additional requests and see the errors as they come in.

## Usage Example

Copy `Extron_Client/metrics_client.py` to your ECS repository. Instantiate and call it as such:

```python
from metrics_client import Metrics

metrics = Metrics(
    processor_name="my_processor",
    uri_type="lambda",
    uri="https://myrandomlambdainstance.lambda-url.us-west-1.on.aws/",
    bearer_token="myrandombearertoken"
)

metrics.trace("Hello World!")
```

Note you can also run the python file on a workstation for testing without having to deploy to a processor.

## Notes

### Time
All timestamps are in UTC and this is intentional
