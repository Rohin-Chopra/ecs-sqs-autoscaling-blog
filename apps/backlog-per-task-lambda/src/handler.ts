import {
  CloudWatchClient,
  PutMetricDataCommand,
} from "@aws-sdk/client-cloudwatch";
import { ECSClient, ListTasksCommand } from "@aws-sdk/client-ecs";
import { GetQueueAttributesCommand, SQSClient } from "@aws-sdk/client-sqs";

const cloudwatchClient = new CloudWatchClient();
const ecsClient = new ECSClient();
const sqsClient = new SQSClient();

async function getApproximateNumberOfMessagesInQueue(queueUrl: string) {
  const { Attributes } = await sqsClient.send(
    new GetQueueAttributesCommand({
      QueueUrl: queueUrl,
      AttributeNames: ["ApproximateNumberOfMessages"],
    })
  );

  console.log(
    `there are ${Attributes?.ApproximateNumberOfMessages} of messages in the queue`
  );

  return +(Attributes?.ApproximateNumberOfMessages || 0);
}

async function getNumberOfActiveTaskInService(
  clusterName: string,
  serviceName: string
) {
  const result = await ecsClient.send(
    new ListTasksCommand({
      cluster: clusterName,
      serviceName: serviceName,
      desiredStatus: "RUNNING",
    })
  );

  console.log(
    `there are ${result.taskArns?.length} tasks running in ${clusterName}/${serviceName}`
  );

  return result.taskArns?.length || 0;
}

async function putMetricData(
  value: number,
  clusterName: string,
  serviceName: string
) {
  console.log(
    `Publishing metric value of ${value} for cluster: ${clusterName} and service: ${serviceName}`
  );

  await cloudwatchClient.send(
    new PutMetricDataCommand({
      Namespace: "ECS/CustomMetrics",
      MetricData: [
        {
          MetricName: "BacklogPerTask",
          Dimensions: [
            {
              Name: "ClusterName",
              Value: clusterName,
            },
            {
              Name: "ServiceName",
              Value: serviceName,
            },
          ],
          Unit: "Count",
          Value: value,
        },
      ],
    })
  );
}

export async function handler() {
  const queueUrl = process.env.QUEUE_URL;
  const ecsClusterName = process.env.ECS_CLUSTER_NAME;
  const ecsServiceName = process.env.ECS_SERVICE_NAME;

  if (!queueUrl || !ecsClusterName || !ecsServiceName) {
    throw new Error("Missing environment variables");
  }

  const approximateNumberOfMessages =
    await getApproximateNumberOfMessagesInQueue(queueUrl);

  const numberOfActiveTaskInService = await getNumberOfActiveTaskInService(
    ecsClusterName,
    ecsServiceName
  );

  const backlogPerTask =
    approximateNumberOfMessages / numberOfActiveTaskInService || 0;

  await putMetricData(backlogPerTask, ecsClusterName, ecsServiceName);
}
