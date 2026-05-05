import datetime
from pathlib import Path

from google.cloud import storage
from google.oauth2 import service_account


def upload_artifacts(
    tmp_dir: str,
    bucket: str,
    cred_path: str,
) -> str | None:
    artifacts = list(Path(tmp_dir).glob("*.png")) + list(Path(tmp_dir).glob("*.html"))
    if not artifacts:
        return None

    credentials = service_account.Credentials.from_service_account_file(
        cred_path,
        scopes=["https://www.googleapis.com/auth/cloud-platform"],
    )
    client = storage.Client(credentials=credentials)
    gcs_bucket = client.bucket(bucket)

    last_url: str | None = None
    for artifact in artifacts:
        blob_name = f"artifacts/{artifact.name}"
        blob = gcs_bucket.blob(blob_name)
        content_type = "image/png" if artifact.suffix == ".png" else "text/html"
        blob.upload_from_filename(str(artifact), content_type=content_type)
        expiry = datetime.timedelta(minutes=15)
        signed_url = blob.generate_signed_url(
            expiration=expiry,
            method="GET",
            version="v4",
        )
        last_url = signed_url

    return last_url
