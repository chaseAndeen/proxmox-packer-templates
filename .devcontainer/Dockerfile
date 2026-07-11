FROM mcr.microsoft.com/devcontainers/python:3.12

ENV DEBIAN_FRONTEND=noninteractive
ENV ANSIBLE_COLLECTIONS_PATHS=/usr/share/ansible/collections

# Install Packer, Ansible, AWS CLI, and supporting tools for template builds.
RUN apt-get update \
  && apt-get install -y --no-install-recommends git curl unzip xorriso lsb-release gpg \
  && rm -rf /var/lib/apt/lists/* \
  && python3 -m pip install --upgrade pip \
  && install -d -m 0755 /etc/apt/keyrings \
  && curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp-archive-keyring.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends packer \
  && pip install --no-cache-dir ansible-core boto3 botocore passlib \
  && curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
  && unzip /tmp/awscliv2.zip -d /tmp \
  && /tmp/aws/install --update \
  && rm -rf /tmp/aws /tmp/awscliv2.zip \
  && mkdir -p /usr/share/ansible/collections \
  && ansible-galaxy collection install -p /usr/share/ansible/collections ansible.posix community.general \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

CMD ["sleep", "infinity"]
