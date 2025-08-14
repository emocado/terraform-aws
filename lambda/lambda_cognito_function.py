import json
import base64
import urllib.parse
import urllib.request
import os

def _basic_auth_header(client_id: str, client_secret: str) -> str:
    creds = f"{client_id}:{client_secret}".encode("utf-8")
    return "Basic " + base64.b64encode(creds).decode("ascii")

def get_cognito_access_token_basic(domain: str, client_id: str, client_secret: str, scope: str = None):
    """Fetch access token using HTTP Basic authentication."""
    token_url = "https://" + domain.rstrip("/") + "/oauth2/token"
    form = {"grant_type": "client_credentials"}
    if scope:
        form["scope"] = scope

    data = urllib.parse.urlencode(form).encode("utf-8")
    req = urllib.request.Request(token_url, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    req.add_header("Authorization", _basic_auth_header(client_id, client_secret))

    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))

def lambda_handler(event, context):
    # Get query params from the API Gateway request
    params = event.get("queryStringParameters") or {}

    domain = os.environ["COGNITO_DOMAIN"]  # example: https://your-domain.auth.us-east-1.amazoncognito.com
    scope = os.environ.get("COGNITO_SCOPE")  # optional
    client_id = params.get("client_id")
    client_secret = params.get("client_secret")

    # Validate required parameters
    if not all([client_id, client_secret]):
        return {
            "statusCode": 400,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET,POST,OPTIONS"
            },
            "body": json.dumps({"error": "Missing required query parameters: client_id, client_secret"})
        }

    try:
        # Get token using Basic Auth style
        token_response = get_cognito_access_token_basic(
            domain=domain,
            client_id=client_id,
            client_secret=client_secret,
            scope=scope
        )

        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET,POST,OPTIONS"
            },
            "body": json.dumps({
                "token_type": token_response.get("token_type"),
                "expires_in": token_response.get("expires_in"),
                "access_token": token_response.get("access_token"),
            })
        }

    except Exception as e:
        return {
            "statusCode": 500,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET,POST,OPTIONS"
            },
            "body": json.dumps({"error": str(e)})
        }
