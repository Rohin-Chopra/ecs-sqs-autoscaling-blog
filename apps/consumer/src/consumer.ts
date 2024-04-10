import {
  DeleteMessageBatchCommand,
  DeleteMessageBatchRequestEntry,
  ReceiveMessageCommand,
  SQSClient,
} from "@aws-sdk/client-sqs"; // ES Modules import

const sqsClient = new SQSClient();

function processOrder() {
  return new Promise((resolve) => {
    setTimeout(() => {
      resolve(true);
    }, 2000);
  });
}

const queueUrl = process.env.QUEUE_URL;

async function receiveMessages() {
  console.log("start");

  const { Messages: messages = [] } = await sqsClient.send(
    new ReceiveMessageCommand({
      QueueUrl: queueUrl,
      MaxNumberOfMessages: 10,
      WaitTimeSeconds: 20,
    })
  );

  const processedMessages: DeleteMessageBatchRequestEntry[] = [];

  for await (const message of messages) {
    try {
      await processOrder();

      processedMessages.push({
        Id: message.MessageId,
        ReceiptHandle: message.ReceiptHandle,
      });
    } catch (error) {
      console.error(`Failed to process message ${message.MessageId}`);
    }
  }

  console.log(
    `Finished processing, successful:${
      processedMessages.length
    } and unsuccessful:${messages.length - processedMessages.length}`
  );

  if (processedMessages.length > 0) {
    await sqsClient.send(
      new DeleteMessageBatchCommand({
        QueueUrl: queueUrl,
        Entries: processedMessages,
      })
    );
  }

  setImmediate(receiveMessages);
}

receiveMessages();
