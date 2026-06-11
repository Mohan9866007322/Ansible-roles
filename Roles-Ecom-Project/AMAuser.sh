#!/bin/bash

AMI_ID="ami-09e69ca1171857250"
SG_ID="sg-0b68b6dbf6ae3c299" # replace with your SG ID
INSTANCES=("mongodb" "redis" "mysql" "rabbitmq" "catalogue" "user" "cart" "shipping" "payment" "dispatch" "frontend")
ZONE_ID="Z05496083TGA6W64AEKNJ" # replace with your ZONE ID
DOMAIN_NAME="marpukosam.xyz" # replace with your domain

# 1. Create the User Data script locally (UPDATED)
cat <<EOF > enable_ssh_password.sh
#!/bin/bash
# Set the password for ec2-user
echo "ec2-user:DevOps321" | chpasswd

# Enable Password Authentication in the main SSH config
sed -i 's/^.*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config

# Forcefully enable it in the drop-in directory used by modern AMIs (Amazon Linux 2023, RHEL 9, etc.)
if [ -d /etc/ssh/sshd_config.d ]; then
    echo "PasswordAuthentication yes" > /etc/ssh/sshd_config.d/99-custom-auth.conf
fi

# Restart the SSH service to apply changes
systemctl restart sshd
EOF

#for instance in ${INSTANCES[@]}
for instance in $@
do
    echo "Creating instance: $instance..."
    
    # 2. Pass the user data file during instance creation
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id $AMI_ID \
        --instance-type t3.micro \
        --security-group-ids $SG_ID \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name, Value=$instance}]" \
        --user-data file://enable_ssh_password.sh \
        --query "Instances[0].InstanceId" \
        --output text)
        
    if [ "$instance" != "frontend" ]
    then
        IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
        RECORD_NAME="$instance.$DOMAIN_NAME"
    else
        # Wait until running to fetch the public IP reliably
        aws ec2 wait instance-running --instance-ids $INSTANCE_ID
        IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
        RECORD_NAME="$DOMAIN_NAME"
    fi
    
    echo "$instance IP address: $IP"

    aws route53 change-resource-record-sets \
    --hosted-zone-id $ZONE_ID \
    --change-batch '
    {
        "Comment": "Creating or Updating a record set for '$instance'"
        ,"Changes": [{
        "Action"              : "UPSERT"
        ,"ResourceRecordSet"  : {
            "Name"              : "'$RECORD_NAME'"
            ,"Type"             : "A"
            ,"TTL"              : 1
            ,"ResourceRecords"  : [{
                "Value"         : "'$IP'"
            }]
        }
        }]
    }'
done

# Clean up the temporary user data file
rm -f enable_ssh_password.sh