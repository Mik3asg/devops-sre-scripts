#!/bin/bash
# user-data-apache-hello.sh
# Simple Apache web server user data script
# Displays instance metadata on the default page
# Uses IMDSv2 token-based metadata retrieval (required on Amazon Linux 2023)
# Usage: paste as-is in EC2 User Data when launching 1 or more instances

yum update -y
yum install -y httpd
systemctl start httpd
systemctl enable httpd

# IMDSv2: get a session token first
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Now use the token to fetch metadata
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)

cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html>
<body style="font-family:sans-serif; text-align:center; padding:60px; background:#f0f4f8;">
  <h1 style="color:#2d6a9f">Hello from <strong>${INSTANCE_ID}</strong>!</h1>
  <table style="margin:auto; border-collapse:collapse; font-size:16px;">
    <tr><td style="padding:8px 20px;color:#555">Instance ID</td><td><strong>${INSTANCE_ID}</strong></td></tr>
    <tr><td style="padding:8px 20px;color:#555">Availability Zone</td><td><strong>${AZ}</strong></td></tr>
    <tr><td style="padding:8px 20px;color:#555">Private IP</td><td><strong>${PRIVATE_IP}</strong></td></tr>
    <tr><td style="padding:8px 20px;color:#555">Public IP</td><td><strong>${PUBLIC_IP}</strong></td></tr>
  </table>
</body>
</html>
EOF
