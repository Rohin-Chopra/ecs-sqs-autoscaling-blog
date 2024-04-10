import {
  SQSClient,
  SendMessageBatchCommand,
  SendMessageBatchRequestEntry,
} from "@aws-sdk/client-sqs";
import { randomUUID } from "crypto";

const sqsClient = new SQSClient();

export async function handler() {
  const queueUrl = process.env.QUEUE_URL;

  if (!queueUrl) {
    throw new Error("Missing environment variables");
  }

  const entries: SendMessageBatchRequestEntry[] = [];

  for (let index = 0; index < 10; index++) {
    entries.push({
      Id: randomUUID(),
      MessageBody: JSON.stringify({
        orderId: randomUUID(),
      }),
    });
  }

  console.log("sending messages to sqs");

  await sqsClient.send(
    new SendMessageBatchCommand({
      QueueUrl: queueUrl,
      Entries: entries,
    })
  );

  console.log("sent messages to sqs");

  // wait for 10 seconds
  await new Promise((resolve, reject) => {
    setTimeout(() => {
      resolve(true);
    }, 3 * 1000);
  });

  setImmediate(handler);
}

handler();
