// user-collection service — single-table DynamoDB access layer.
// One table (sunsip-data) holds users, preferences, saved combinations,
// password-reset tokens and rate limits, keyed by PK/SK. The brief scores
// "one DynamoDB table sunsip-data" — never add a second table.

import {
  DynamoDBClient,
  GetItemCommand,
  PutItemCommand,
  DeleteItemCommand,
  UpdateItemCommand,
  QueryCommand,
} from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';

const REGION = process.env.AWS_REGION || 'ap-southeast-2';

// Local DynamoDB (docker) is selected by DYNAMO_ENDPOINT, e.g.
// http://localhost:8000. In AWS, DynamoDB is region-scoped — no endpoint.
const endpoint = process.env.DYNAMO_ENDPOINT || undefined;

export const ddb = new DynamoDBClient({
  region: REGION,
  ...(endpoint ? { endpoint } : {}),
  // Local ddb ignores real credentials; in AWS the ECS task role supplies them.
  ...(endpoint
    ? { credentials: { accessKeyId: 'local', secretAccessKey: 'local' } }
    : {}),
});

export const TABLE = process.env.DDB_TABLE || 'sunsip-data';

type Item = Record<string, any>;

// ---------------------------------------------------------------- helpers

export function userPk(userId: string): string {
  return `USER#${userId}`;
}

// ---------------------------------------------------------------- users

/** Put a user item. Item shape: PK, SK='PROFILE', GSI2PK=EMAIL#<email>, ... */
export async function putUser(item: Item): Promise<void> {
  await ddb.send(new PutItemCommand({ TableName: TABLE, Item: marshall(item) }));
}

/** Fetch one item by full key. */
export async function getItem(pk: string, sk: string): Promise<Item | null> {
  const out = await ddb.send(
    new GetItemCommand({ TableName: TABLE, Key: marshall({ PK: pk, SK: sk }) })
  );
  return out.Item ? unmarshall(out.Item) : null;
}

/** Fetch all items sharing the PK (optionally restricted to one SK prefix). */
export async function queryByPK(pk: string, { skPrefix }: { skPrefix?: string } = {}): Promise<Item[]> {
  const params: any = {
    TableName: TABLE,
    KeyConditionExpression: '#pk = :pk',
    ExpressionAttributeNames: { '#pk': 'PK' },
    ExpressionAttributeValues: marshall({ ':pk': pk }),
  };
  if (skPrefix) {
    params.KeyConditionExpression += ' AND begins_with(#sk, :skp)';
    params.ExpressionAttributeNames['#sk'] = 'SK';
    params.ExpressionAttributeValues[':skp'] = { S: skPrefix };
  }
  const out = await ddb.send(new QueryCommand(params));
  return (out.Items ?? []).map((r: any) => unmarshall(r));
}

/** Query a global secondary index by its partition key (optionally SK prefix). */
export async function queryByIndex(
  indexName: string,
  keyAttr: string,
  keyVal: string,
  { skPrefix }: { skPrefix?: string } = {}
): Promise<Item[]> {
  const params: any = {
    TableName: TABLE,
    IndexName: indexName,
    KeyConditionExpression: '#pk = :pk',
    ExpressionAttributeNames: { '#pk': keyAttr },
    ExpressionAttributeValues: marshall({ ':pk': keyVal }),
  };
  if (skPrefix) {
    params.KeyConditionExpression += ' AND begins_with(#sk, :skp)';
    params.ExpressionAttributeNames['#sk'] = 'SK';
    params.ExpressionAttributeValues[':skp'] = { S: skPrefix };
  }
  const out = await ddb.send(new QueryCommand(params));
  return (out.Items ?? []).map((r: any) => unmarshall(r));
}

/** Generic update — merges attrs into the item identified by (pk, sk). */
export async function updateItem(pk: string, sk: string, attrs: Item): Promise<Item | null> {
  const names: Record<string, string> = {};
  const values: Record<string, unknown> = {};
  const sets: string[] = [];
  Object.entries(attrs).forEach(([key, value]) => {
    names[`#${key}`] = key;
    values[`:${key}`] = value;
    sets.push(`#${key} = :${key}`);
  });

  const out = await ddb.send(
    new UpdateItemCommand({
      TableName: TABLE,
      Key: marshall({ PK: pk, SK: sk }),
      UpdateExpression: `SET ${sets.join(', ')}`,
      ExpressionAttributeNames: names,
      ExpressionAttributeValues: marshall(values as any),
      ReturnValues: 'ALL_NEW',
    })
  );
  return out.Attributes ? unmarshall(out.Attributes) : null;
}

/** Delete one item by full key. */
export async function deleteItem(pk: string, sk: string): Promise<void> {
  await ddb.send(new DeleteItemCommand({ TableName: TABLE, Key: marshall({ PK: pk, SK: sk }) }));
}

/** Conditional put — succeeds only when (PK, SK) does not exist yet. */
export async function putIfAbsent(item: Item): Promise<boolean> {
  try {
    await ddb.send(
      new PutItemCommand({
        TableName: TABLE,
        Item: marshall(item),
        ConditionExpression: 'attribute_not_exists(PK)',
      })
    );
    return true;
  } catch (err: any) {
    if (err?.name === 'ConditionalCheckFailedException') return false;
    throw err;
  }
}