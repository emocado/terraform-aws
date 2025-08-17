import https from "node:https";

const API_URL = process.env.API_URL; // full path to /oauth2/token
const CLIENT_ID = process.env.CLIENT_ID;
const CLIENT_SECRET = process.env.CLIENT_SECRET;
const SCOPE = process.env.SCOPE || "${var.cognito_resource_server_identifier}/read_access";

function base64Basic(id, secret) {
  return Buffer.from(`${id}:${secret}`, "ascii").toString("base64");
}

function postForm(urlStr, headers, body) {
  return new Promise((resolve, reject) => {
    try {
      const url = new URL(urlStr);
      const options = {
        method: "POST",
        hostname: url.hostname,
        path: url.pathname + url.search,
        headers: headers,
      };

      const req = https.request(options, (res) => {
        let data = "";
        res.on("data", (chunk) => (data += chunk));
        res.on("end", () => {
          resolve({
            statusCode: res.statusCode,
            headers: res.headers,
            body: data,
          });
        });
      });

      req.on("error", reject);
      req.write(body);
      req.end();
    } catch (e) {
      reject(e);
    }
  });
}

export const handler = async () => {
  if (!API_URL || !CLIENT_ID || !CLIENT_SECRET) {
    return {
      statusCode: 500,
      body: JSON.stringify({
        error: "Missing API_URL, CLIENT_ID or CLIENT_SECRET env vars",
      }),
    };
  }

  const basic = base64Basic(CLIENT_ID, CLIENT_SECRET);
  const body = `grant_type=client_credentials&scope=${encodeURIComponent(SCOPE)}`;

  const headers = {
    "Content-Type": "application/x-www-form-urlencoded",
    "Authorization": `Basic ${basic}`,
    "Content-Length": Buffer.byteLength(body),
  };

  try {
    const resp = await postForm(API_URL, headers, body);

    let parsed;
    try { parsed = JSON.parse(resp.body); }
    catch { parsed = { body_text: resp.body }; }

    return {
      statusCode: 200,
      body: JSON.stringify({
        requested_url: API_URL,
        status_code: resp.statusCode,
        headers: resp.headers,
        body: parsed,
      }),
    };
  } catch (err) {
    return {
      statusCode: 500,
      body: JSON.stringify({ error: "request_failed", message: String(err) }),
    };
  }
};