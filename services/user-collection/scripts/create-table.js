// Creates the single sunsip-data table (local DynamoDB or real AWS) and
// prints its description. Run: node services/user-collection/scripts/create-table.js
// The same PK/SK/GSI design is reproduced by Terraform in Phase 2 — the brief
// scores the table being created by IaC, this script is for local dev only.

import {
  DynamoDBClient,
  CreateTableCommand,
  DescribeTableCommand,
} from '@aws-sdk/client-dynamodb';

const REGION = process.env.AWS_REGION || 'ap-southeast-2';
const endpoint = process.env.DYNAMO_ENDPOINT || undefined;
const TABLE = process.env.DDB_TABLE || 'sunsip-data';

const ddb = new DynamoDBClient({
  region: REGION,
  ...(endpoint ? { endpoint } : {}),
  ...(endpoint
    ? { credentials: { accessKeyId: 'local', secretAccessKey: 'local' } }
    : {}),
});

async function main() {
  try {
    const existing = await ddb.send(
      new DescribeTableCommand({ TableName: TABLE })
    );
    console.log(`Table "${TABLE}" already exists (status: ${existing.Table?.TableStatus}).`);
    return;
  } catch {
    // not found — create it
  }

  await ddb.send(
    new CreateTableCommand({
      TableName: TABLE,
      KeySchema: [
        { AttributeName: 'PK', KeyType: 'HASH' },
        { AttributeName: 'SK', KeyType: 'RANGE' },
      ],
      AttributeDefinitions: [
        { AttributeName: 'PK', AttributeType: 'S' },
        { AttributeName: 'SK', AttributeType: 'S' },
        { AttributeName: 'GSI1PK', AttributeType: 'S' },
        { AttributeName: 'GSI2PK', AttributeType: 'S' },
        { AttributeName: 'GSI2SK', AttributeType: 'S' },
      ],
      GlobalSecondaryIndexes: [
        {
          // Time-ordered access (e.g. newest-first favourites per user)
          IndexName: 'GSI1',
          KeySchema: [
            { AttributeName: 'GSI1PK', KeyType: 'HASH' },
            { AttributeName: 'SK', KeyType: 'RANGE' },
          ],
          Projection: { ProjectionType: 'ALL' },
        },
        {
          // Email lookup (sign-in, forgot-password, duplicate-signup check)
          IndexName: 'GSI2',
          KeySchema: [
            { AttributeName: 'GSI2PK', KeyType: 'HASH' },
            { AttributeName: 'GSI2SK', KeyType: 'RANGE' },
          ],
          Projection: { ProjectionType: 'ALL' },
        },
      ],
      BillingMode: 'PAY_PER_REQUEST',
    })
  );
  console.log(`Table "${TABLE}" created.`);
}

main().catch((err) => {
  console.error('create-table failed:', err.message);
  process.exit(1);
});