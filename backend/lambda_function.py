import json
import boto3
import os

# Initialize the DynamoDB resource outside the handler for performance (Warm Start)
dynamodb = boto3.resource('dynamodb')

# Use an environment variable for the table name, falling back to your specific name
TABLE_NAME = os.environ.get('TABLE_NAME', 'visitor-count-table')
table = dynamodb.Table(TABLE_NAME)

def lambda_handler(event, context):
    try:
        # 1. Update the item in DynamoDB atomically
        response = table.update_item(
            Key={
                'id': 'visitors' # This is the specific row in your table
            },
            UpdateExpression='ADD count_value :inc',
            ExpressionAttributeValues={
                ':inc': 1
            },
            ReturnValues="UPDATED_NEW"
        )
        
        # 2. Extract the new count
        new_count = int(response['Attributes']['count_value'])
        
        # 3. Return the response to the frontend
        return {
            'statusCode': 200,
            # CORS HEADERS: ABSOLUTELY CRITICAL for frontend fetch() to work
            'headers': {
                'Access-Control-Allow-Origin': '*', # Or your domain: 'https://henriquezw.click'
                'Access-Control-Allow-Headers': 'Content-Type',
                'Access-Control-Allow-Methods': 'OPTIONS,POST,GET'
            },
            'body': json.dumps({
                'visits': new_count
            })
        }
        
    except Exception as e:
        print(f"Error updating DynamoDB: {e}")
        return {
            'statusCode': 500,
            'headers': {
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({'error': 'Could not update visitor count'})
        }