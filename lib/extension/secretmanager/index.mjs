import fetch from "node-fetch";
import express from "express";
import {
  GetSecretValueCommand,
  SecretsManagerClient,
} from "@aws-sdk/client-secrets-manager";

const extensionsApiUrl = `http://${process.env.AWS_LAMBDA_RUNTIME_API}/2020-01-01/extension`;
const extensionName = "secretmanager"
const httpServerPort = process.env.SECRETMANAGER_PORT || 3000;

const app = express();

app.use(express.json());

app.get("/secret/:secretName", async (req, res) => {
  const { secretName } = req.params;
  const secret = await getSecretValue(secretName);
  res.json({ secret });
});

async function getSecretValue(secretName) {
  console.log("Fetching secret:", secretName);
  const client = new SecretsManagerClient();
  const response = await client.send(
    new GetSecretValueCommand({
      SecretId: secretName,
    }),
  );
  console.log("response:", response);

  if (response.SecretString) {
    return response.SecretString;
  }

  if (response.SecretBinary) {
    return response.SecretBinary;
  }

  return null;
}

async function registerToExtensionsApi() {
  const res = await fetch(`${extensionsApiUrl}/register`, {
    method: "post",
    headers: {
      "Content-Type": "application/json",
      "Lambda-Extension-Name": extensionName,
    },
    body: JSON.stringify({ events: ["INVOKE", "SHUTDOWN"] }),
  });

  if (res.ok) return res.headers.get("lambda-extension-identifier");

  const error = await res.text();
  console.error("Error: " + error);
}

async function getNextEvent(extensionId) {
  const res = await fetch(`${extensionsApiUrl}/event/next`, {
    method: "get",
    headers: {
      "Content-Type": "application/json",
      "Lambda-Extension-Identifier": extensionId,
    },
  });

  if (res.ok) return await res.json();

  const error = await res.text();
  console.log("Error: " + error);
}

let isShuttingDown = false;
let isShutDown = false;

function handleShutdown(server) {
  return async function() {
    if (isShuttingDown) return;
    isShuttingDown = true;
    console.log("Shutting down...");
    server.close()
    await new Promise(resolve => setTimeout(resolve, 1000));
    if (isShutDown) return;
    console.log("Shutdown timeout exceeded...");
    process.exit(2); // Terminate abnormally if timeout exceeded
  }
}

export default async function main() {
  const server = app.listen(httpServerPort, () => {
    console.log(`Server running on port ${httpServerPort}`);
  });

  process.on("SIGINT", handleShutdown(server));
  process.on("SIGTERM", handleShutdown(server)); 
  
  try {
    const extensionId = await registerToExtensionsApi();
    console.log("registered with ID: ", extensionId);

    while (!isShuttingDown) {
      try {
        const { eventType } = await getNextEvent(extensionId);
        switch (eventType) {
          case "SHUTDOWN":
            console.log("extension SHUTDOWN");
            await handleShutdown();
            return;
          case "INVOKE":
            console.log("extension INVOKE");
            break;
          default:
            console.error("Unknown event type:", eventType);
        }
      } catch (error) {
        if (isShuttingDown) break;
        console.error("Error in event loop:", error);
      }
    }
  } catch (error) {
    console.error("Fatal error:", error);
    process.exit(1);
  } finally {
    isShutDown = true;
  }

  console.log("Shutdown complete");
}
