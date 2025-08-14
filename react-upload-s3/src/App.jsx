import React, { useState } from 'react';

class CognitoClientCredentials {
  constructor({ cognitoDomain, clientId, clientSecret, scope }) {
    this.cognitoDomain = cognitoDomain;
    this.clientId = clientId;
    this.clientSecret = clientSecret;
    this.scope = scope;
    this.tokenData = null;
    this.tokenExpiry = null;
  }

  async getToken() {
    const now = Math.floor(Date.now() / 1000);
    if (this.tokenData && this.tokenExpiry && now < this.tokenExpiry - 30) {
      return this.tokenData.access_token;
    }
    await this.fetchToken();
    return this.tokenData.access_token;
  }

  async fetchToken() {
    const tokenUrl = `https://${this.cognitoDomain}/oauth2/token`;
    const authHeader = 'Basic ' + btoa(`${this.clientId}:${this.clientSecret}`);

    const params = new URLSearchParams();
    params.append('grant_type', 'client_credentials');
    if (this.scope) {
      params.append('scope', this.scope);
    }

    const response = await fetch(tokenUrl, {
      method: 'POST',
      headers: {
        Authorization: authHeader,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: params.toString(),
    });

    if (!response.ok) {
      let errorData;
      try {
        errorData = await response.json();
      } catch {
        errorData = null;
      }
      throw new Error(`Token request failed: ${response.status} - ${JSON.stringify(errorData)}`);
    }

    this.tokenData = await response.json();
    this.tokenExpiry = Math.floor(Date.now() / 1000) + this.tokenData.expires_in;
  }
}

function App() {
  const cognitoDomain = import.meta.env.VITE_COGNITO_DOMAIN;
  const presignApiEndpoint = import.meta.env.VITE_PRESIGN_API_ENDPOINT;
  const clientId = import.meta.env.VITE_COGNITO_CLIENT_ID;
  const clientSecret = import.meta.env.VITE_COGNITO_CLIENT_SECRET;
  const scope = import.meta.env.VITE_COGNITO_SCOPE;

  const [file, setFile] = useState(null);
  const [status, setStatus] = useState('');
  const [uploadedLink, setUploadedLink] = useState('');
  const [role, setRole] = useState('areamgr'); // dropdown selection

  const client = React.useMemo(() => {
    if (!cognitoDomain || !clientId || !clientSecret) {
      return null;
    }
    return new CognitoClientCredentials({
      cognitoDomain,
      clientId,
      clientSecret,
      scope,
    });
  }, [cognitoDomain, clientId, clientSecret, scope]);

  const getPresignedUrl = async (jwtToken, filename, contentType) => {
    if (!presignApiEndpoint) {
      throw new Error('Missing presign API env config. Check your .env values.');
    }

    const res = await fetch(
      presignApiEndpoint +
        `?filename=${encodeURIComponent(filename)}&contentType=${encodeURIComponent(contentType)}`,
      {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${jwtToken}`,
        },
      }
    );

    if (!res.ok) {
      const text = await res.text().catch(() => '');
      throw new Error(`Failed to get presigned URL: ${res.status} ${res.statusText} ${text}`);
    }

    return res.json(); // expected: { url, publicUrl? }
  };

  const handleUpload = async () => {
    setStatus('');
    setUploadedLink('');

    if (!file) {
      alert('Please select a file to upload.');
      return;
    }

    if (!client) {
      setStatus('Missing Cognito client configuration.');
      return;
    }

    try {
      setStatus('Authenticating with Cognito...');
      const jwtToken = await client.getToken();

      const finalFilename = `${role}/${file.name}`;

      setStatus('Requesting presigned URL...');
      const { url: presignedUrl, publicUrl } = await getPresignedUrl(
        jwtToken,
        finalFilename,
        file.type || 'application/octet-stream'
      );

      setStatus('Uploading to S3...');
      const putRes = await fetch(presignedUrl, {
        method: 'PUT',
        headers: {
          'Content-Type': file.type || 'application/octet-stream',
        },
        body: file,
      });

      if (!putRes.ok) {
        const text = await putRes.text().catch(() => '');
        throw new Error(`Upload failed: ${putRes.status} ${putRes.statusText} ${text}`);
      }

      setStatus('Upload successful!');
      setUploadedLink(publicUrl || 'Uploaded. No public URL returned by API.');
    } catch (err) {
      setStatus(`Error: ${err.message}`);
    }
  };

  return (
    <div style={styles.container}>
      <h2 style={styles.h2}>S3 File Uploader: upload manager jar file for pushing to ECR</h2>

      {/* Guide for the user */}
      <div style={styles.guide}>
        <p>
          <strong>Important:</strong> Your file should be named {' '}
          <code>snapshot-1.jar</code>.
        </p>
      </div>

      {/* Role selection dropdown */}
      <label>
        Select Role: &nbsp;
        <select value={role} onChange={(e) => setRole(e.target.value)}>
          <option value="areamgr">areamgr</option>
          <option value="violationmgr">violationmgr</option>
        </select>
      </label>

      <br />
      <br />

      <input
        type="file"
        onChange={(e) => setFile(e.target.files && e.target.files[0] ? e.target.files[0] : null)}
      />
      <br />
      <br />
      <button onClick={handleUpload}>Upload to S3</button>

      <div style={styles.status}>{status}</div>
      <div style={styles.link}>
        {uploadedLink && (
          <a href={uploadedLink} target="_blank" rel="noreferrer">
            {uploadedLink}
          </a>
        )}
      </div>
    </div>
  );
}

const styles = {
  container: {
    fontFamily: 'Arial, sans-serif',
    maxWidth: 500,
    margin: '50px auto',
    padding: 20,
    border: '1px solid #ccc',
    borderRadius: 8,
  },
  h2: { textAlign: 'center' },
  guide: {
    background: '#f5f5f5',
    padding: 10,
    marginBottom: 15,
    fontSize: '0.9em',
    borderRadius: 5,
    border: '1px solid #ddd',
  },
  status: { marginTop: 15, fontWeight: 'bold' },
  link: { marginTop: 10, wordBreak: 'break-all' },
};

export default App;
