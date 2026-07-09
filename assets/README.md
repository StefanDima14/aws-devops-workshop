# assets/

Put the video the app should play here (e.g. `video.mp4`), then either:

**A) Let Terraform upload it on apply** — set in `terraform/terraform.tfvars`:

```hcl
video_source_path = "../assets/video.mp4"
video_object_key  = "video.mp4"
```

**B) Upload it yourself** after the bucket exists:

```bash
BUCKET=$(cd terraform && terraform output -raw video_bucket_name)
aws s3 cp assets/video.mp4 "s3://$BUCKET/video.mp4"
```

The bucket is **private**. The app streams the object via short-lived
**presigned URLs**, so the file is never publicly exposed. Video binaries are
git-ignored (`assets/*.mp4`) — they belong in S3, not the repo.
