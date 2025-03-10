import { SQS } from '@aws-sdk/client-sqs';
import fetch from "node-fetch";

const sqs = new SQS();
const sqsTimeout = 2500;

async function getSecret() {
    const secretName = process.env.SECRET_NAME;
    const secretmanagerPort = process.env.SECRETMANAGER_PORT;
    const response = await fetch(`http://localhost:${secretmanagerPort}/secret/${secretName}`);
    const data = await response.json();

    return data ? data.secret : null;
}

export const handler = async (event) => {
    try {
        const message = JSON.parse(event.Records[0].Sns.Message);
        const { num1, num2 } = message;
        const sum = num1 + num2;

        const secret = await getSecret();
        const response = JSON.stringify({ sum, num1, num2, secret })
        
        const sendMessagePromise = sqs.sendMessage({
            QueueUrl: process.env.SQS_QUEUE_URL,
            MessageBody: response,
            MessageGroupId: 'calculation-result'
        });

        await Promise.race([
            sendMessagePromise,
            new Promise((_, reject) => 
                setTimeout(() => reject(new Error('SQS operation timed out')), sqsTimeout)
            )
        ]);

        return {
            statusCode: 200,
            body: response,
        };
    } catch (error) {
        console.error('Error in lambda execution:', error);
        throw error;
    }
};
