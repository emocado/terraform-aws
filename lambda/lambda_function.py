import os
import boto3
import mimetypes


def lambda_handler(event, context):
    s3 = boto3.client('s3', region_name="ap-southeast-1", endpoint_url='https://s3.ap-southeast-1.amazonaws.com')
    
    params = event.get('queryStringParameters') or {}
    filename = params.get('filename')
    
    if not filename:
        return {
            'statusCode': 400,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Methods': 'GET,POST,OPTIONS'
            },
            'body': '{"error": "Missing \'filename\' query parameter."}'
        }

    # Guess content type from file extension
    filetype, _ = mimetypes.guess_type(filename)
    if filetype is None:
        filetype = 'application/octet-stream'  # default fallback type

    bucket_name = os.environ['BUCKET_NAME']

    presign_params = {
        'Bucket': bucket_name,
        'Key': filename,
        'ContentType': filetype
    }

    url = s3.generate_presigned_url(
        ClientMethod='put_object',
        Params=presign_params,
        ExpiresIn=900
    )

    print(f"Filename: {filename}, Guessed Content-Type: {filetype}")
    print(f"Generated presigned URL: {url}")

    return {
        'statusCode': 200,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET,POST,OPTIONS'
        },
        'body': '{"url": "%s"}' % url
    }
