# Jenkins Server on AWS via Terraform

A foundational Infrastructure as Code project that provisions a Jenkins CI/CD server on AWS using Terraform. Built as part of the Level Up In Tech Cloud DevOps Engineering program.

---

## Project Overview

This project deploys a Jenkins server on AWS EC2 using Terraform to manage and version control the infrastructure. Using Terraform means the environment is reproducible, trackable, and can be deployed consistently across multiple environments — no clicking around the console hoping you remembered every setting.

**All infrastructure is defined in a single `main.tf` file (monolith pattern), which is acceptable for foundational projects before modularization becomes necessary.**

---

## Architecture

```
Default VPC (us-east-1)
    └── EC2 Instance (t2.micro, Amazon Linux 2023)
            └── Jenkins 2.555.1 (port 8080)
            └── Security Group
                    ├── Port 22  — SSH from designated IP only
                    └── Port 8080 — Jenkins UI (open)

S3 Bucket — jenkins-artifacts-shawr-2025
    └── Public access blocked at bucket level
```

---

## Resources Deployed

| Resource | Name | Purpose |
|---|---|---|
| `aws_instance` | `jenkins-server` | Jenkins CI/CD controller |
| `aws_security_group` | `jenkins-security-group` | Controls inbound/outbound traffic |
| `aws_s3_bucket` | `jenkins-artifacts-shawr-2025` | Private artifact storage |
| `aws_s3_bucket_public_access_block` | — | Enforces private access on S3 bucket |

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) v1.5+
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) configured with valid credentials
- An AWS account with permissions to create EC2, S3, and Security Group resources
- Git

---

## Usage

### 1. Clone the repo

```bash
git clone https://github.com/mattrshaw4/jenkins-terraform.git
cd jenkins-terraform
```

### 2. Update your IP address

In `main.tf`, find the Security Group ingress rule for port 22 and replace the CIDR block with your public IP:

```hcl
cidr_blocks = ["YOUR.IP.ADDRESS.HERE/32"]
```

Get your current IP:
```bash
curl -s https://checkip.amazonaws.com
```

### 3. Initialize, plan, and apply

```bash
terraform init
terraform plan
terraform apply
```

Type `yes` when prompted. Terraform will output your Jenkins URL when complete:

```
jenkins_url = "http://<public-ip>:8080"
```

### 4. Wait for Jenkins to bootstrap

Allow **4–6 minutes** after apply completes. The EC2 user_data script installs Java 21 and Jenkins on first boot. Jenkins is fully ready when `systemctl status jenkins` shows `Active: active (running)`.

### 5. Get the initial admin password

Connect to the instance via EC2 Instance Connect in the AWS Console, then run:

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

### 6. Access Jenkins

Open `http://<public-ip>:8080` in your browser and enter the admin password to unlock Jenkins.

---

## Security Notes

- Port 22 (SSH) is restricted to a single IP address — not open to the world
- The S3 bucket has all four public access block settings enabled
- `gpgcheck=0` is set in the Jenkins repo configuration due to a GPG key rotation issue with the Jenkins stable repository at time of deployment. In a production environment, you would pin the current verified GPG key from the [official Jenkins documentation](https://www.jenkins.io/doc/book/installing/linux/)
- Terraform state files are excluded from version control via `.gitignore`

---

## Cleanup

To avoid ongoing AWS charges, destroy all resources when done:

```bash
terraform destroy
```

---

## Challenges

This section documents the real issues encountered during deployment — because infrastructure work rarely goes cleanly on the first run, and documenting what broke is just as valuable as documenting what worked.

---

### 1. Wrong AMI — Amazon Linux 2 vs Amazon Linux 2023

**What happened:** The hardcoded AMI ID `ami-0c02fb55956c7d316` resolved to Amazon Linux 2, not AL2023 as intended. The cloud-init log revealed `Cloud-init v. 19.3-46.amzn2` — a dead giveaway.

**Why it mattered:** AL2 uses `yum` and doesn't have `java-21-amazon-corretto` in its repos. AL2023 uses `dnf` and does.

**Fix:** Replaced the hardcoded AMI ID with a Terraform `data "aws_ami"` data source that dynamically resolves the latest AL2023 AMI by name filter. Added `user_data_replace_on_change = true` to force instance replacement when the bootstrap script changes.

**Lesson:** Never hardcode AMI IDs. They differ by region and rotate with OS updates. A data source with filters is more reliable and requires zero maintenance.

---

### 2. Java Version — Jenkins Now Requires Java 21

**What happened:** Jenkins started but immediately crashed with:
```
Running with Java 17... which is older than the minimum required version (Java 21).
Supported Java versions are: [21, 25]
```

**Why it mattered:** Jenkins updated its minimum Java requirement between when the project was written and when it was deployed. `java-17-amazon-corretto` installed fine it just wasn't accepted by the current Jenkins version.

**Fix:** Updated `user_data` to install `java-21-amazon-corretto`.

**Lesson:** Always check the current runtime requirements against official documentation before writing your bootstrap script. Jenkins' Java support page is updated with each major release.

---

### 3. `wget` Not Available on Amazon Linux 2023

**What happened:** The bootstrap script used `wget` to download the Jenkins repo file. AL2023 doesn't include `wget` by default.

```
line 11: wget: command not found
```

**Fix:** Replaced `wget` with `curl -o`, which ships with AL2023.

**Lesson:** Don't assume tool availability across distributions. AL2023 is a clean-room OS that ships with less than AL2 by design.

---

### 4. GPG Key Must Be Imported Before the Repo Is Loaded

**What happened:** dnf failed to load the Jenkins repo file because the GPG key import came *after* the repo was added. dnf validates the key at load time, not at install time.

**Fix:** Moved `rpm --import` to run *before* the `curl` that writes the repo file.

**Lesson:** Order matters in bootstrap scripts. When dnf loads a repo with `gpgcheck=1`, it validates the key immediately not at install time.

---

### 5. Nested Heredoc Mangling in Terraform user_data

**What happened:** Using a heredoc (`<< 'REPO'`) inside Terraform's heredoc (`<<-USERDATA`) caused formatting and encoding issues. The repo file was being written but dnf couldn't parse it.

**Fix:** Replaced the nested heredoc with `printf` to write the repo file contents directly, which Terraform handles cleanly:

```bash
printf '[jenkins]\nname=Jenkins-stable\nbaseurl=https://pkg.jenkins.io/redhat-stable\ngpgcheck=0\nenabled=1\n' > /etc/yum.repos.d/jenkins.repo
```

**Lesson:** Avoid nested heredocs in Terraform `user_data`. Use `printf` or `tee` to write multi-line files inline.

---

### 6. Jenkins GPG Key Rotation Breaking Package Installation

**What happened:** Even after the repo file was loading correctly, `dnf install jenkins` failed with:

```
GPG check FAILED
The GPG keys listed for the "Jenkins-stable" repository are already installed
but they are not correct for this package.
```

Jenkins had rotated their package signing key. The key in the repo pointed to `jenkins.io-2023.key`, but the current package (`jenkins-2.555.1`) was signed with a newer key.

**Fix:** Set `gpgcheck=0` in the repo file for this foundational project. In production, the correct approach is to identify the current verified signing key from the [official Jenkins Linux installation docs](https://www.jenkins.io/doc/book/installing/linux/) and pin it explicitly.

**Lesson:** GPG key rotation is a real operational concern. Production Jenkins deployments should pin a specific verified key and have a process for key rotation, not disable checking entirely.

---

## Screenshot

Jenkins UI accessible at `http://<public-ip>:8080` after successful deployment:

![Jenkins Welcome Screen]
<img width="2056" height="680" alt="terraform 6" src="https://github.com/user-attachments/assets/3f878368-f9f7-4d64-ac73-48aaa15fb3b8" />


---

## Author

**Matt Shaw** — Cloud DevOps Engineer  
[GitHub](https://github.com/mattrshaw4) · [Medium](https://medium.com/@matt.r.shaw4) · 
