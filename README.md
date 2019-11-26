# IAM Roles for Service Accounts (IRSA)

IAM Roles for Service Accounts allows pods to be first class citizens in IAM.

Rather than intercepting the requests to the EC2 metadata API to perform a call to the STS API to retrieve temporary credentials, changes were made in the AWS identity APIs to recognize Kubernetes pods. By combining an OpenID Connect (OIDC) identity provider and Kubernetes service account annotations, you can now use IAM roles at the pod level.

Here’s how the different pieces from AWS IAM and Kubernetes all play together to realize IRSA in EKS (dotted lines are actions, solid ones are properties or relations):

[![IRSA diagram](https://d2908q01vomqb2.cloudfront.net/ca3512f4dfa95a03169c5a670a4c91a19b3077b4/2019/08/12/irp-eks-setup-1024x1015.png)]


Drilling further down into the solution: OIDC federation access allows you to assume IAM roles via the Secure Token Service (STS), enabling authentication with an OIDC provider, receiving a JSON Web Token (JWT), which in turn can be used to assume an IAM role. Kubernetes, on the other hand, can issue so-called projected service account tokens, which happen to be valid OIDC JWTs for pods. Our setup equips each pod with a cryptographically-signed token that can be verified by STS against the OIDC provider of your choice to establish the pod’s identity. Additionally, we’ve updated AWS SDKs with a new credential provider that calls sts:AssumeRoleWithWebIdentity, exchanging the Kubernetes-issued OIDC token for AWS role credentials.

The resulting solution is now available in EKS, where we manage the control plane and run the webhook responsible for injecting the necessary environment variables and projected volume. 


# Requirements

Terraform.

```sh
curl -sLO https://releases.hashicorp.com/terraform/0.12.16/terraform_0.12.16_linux_amd64.zip
unzip terraform_*_linux_amd64.zip
sudo mv terraform /usr/local/bin/terraform
rm terraform*zip
```

Kubergrunt. Used for the getting the OIDC thumbprint.

```sh
curl -sLO https://github.com/gruntwork-io/kubergrunt/releases/download/v0.5.8/kubergrunt_linux_amd64  
chmod +x ./kubergrunt_linux_amd64
sudo mv kubergrunt_linux_amd64 /usr/local/bin/kubergrunt
```

Setup IAM Role using this [guide](https://eksworkshop.com/prerequisites/iamrole/) or have proper AWS credentials at hand.

Double check with the output of `aws sts get-caller-identity`.

Optional

`kubectl` autocomplete

```sh
source <(kubectl completion bash)
alias k=kubectl
complete -F __start_kubectl k
```

Install direnv.net


# Create the cluster

Using terraform.

```sh
terraform init
terraform validate

terraform plan -var-file=env_vars/test.tfvars
terraform plan -var-file=env_vars/test.tfvars -out planfile
terraform apply planfile
```

It takes 10 to 15 mins for the command to complete.



# Accessing the cluster

To create your kubeconfig file manually

```
eks_cluster_name=$(terraform output eks_cluster_name)
endpoint_url=$(terraform output eks_cluster_endpoint)
# aws eks describe-cluster --name ${eks_cluster_name}
base64_encoded_ca_cert=$(aws eks describe-cluster --name ${eks_cluster_name} | jq -r '.cluster.certificateAuthority.data')

cat <<_EOF_> kubeconfig_${eks_cluster_name}
apiVersion: v1
clusters:
- cluster:
    server: ${endpoint_url}
    certificate-authority-data: ${base64_encoded_ca_cert}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: aws
  name: aws
current-context: aws
kind: Config
preferences: {}
users:
- name: aws
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1alpha1
      command: aws-iam-authenticator
      args:
        - "token"
        - "-i"
        - "${eks_cluster_name}"
_EOF_
export KUBECONFIG=./kubeconfig
```


# Workers

Adding nodes


https://docs.aws.amazon.com/eks/latest/userguide/launch-workers.html

```
worker_node_role_arn=$(terraform output worker_node_role_arn)
cat <<_EOF_> aws-auth-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: ${worker_node_role_arn}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
_EOF_
kubectl apply -f aws-auth-cm.yaml
kubectl get nodes
```       


The nodes should be up and ready. 

The pods however, not all might be ok:

```sh
$ k get pods -n kube-system
NAME                       READY   STATUS              RESTARTS   AGE
aws-node-4mkh2             1/1     Running             0          103s
aws-node-8sg8h             1/1     Running             0          102s
aws-node-ntfft             1/1     Running             0          107s
aws-node-pxtk6             1/1     Running             0          107s
coredns-67b9c4d455-78tcz   0/1     ContainerCreating   0          14m
coredns-67b9c4d455-mns85   0/1     ContainerCreating   0          14m
kube-proxy-b42bt           1/1     Running             0          102s
kube-proxy-df8rg           1/1     Running             0          107s
kube-proxy-mccwn           1/1     Running             0          107s
kube-proxy-s8m8t           1/1     Running             0          103s
```

What's the problem with the coredns pods? 

The VPC CNI is missing credentials in order to retrieve the IP from the AWS endpoint.


# Update VPC CNI service account

The `aws-node` daemonset is responsible for interacting with the AWS endpoints. Let's make sure it has permissions to acomplish its tasks.

```
eks_cluster_name=$(terraform output eks_cluster_name)
# aws iam get-role --role-name "${eks_cluster_name}-aws-node"
aws_iam_role_aws_node=$(aws iam get-role --role-name "${eks_cluster_name}-aws-node" | jq -r '.Role.Arn')

cat <<_EOF_>sa_aws_node.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-node
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: ${aws_iam_role_aws_node}
_EOF_
kubectl apply -f sa_aws_node.yaml
kubectl rollout restart -n kube-system daemonset.apps/aws-node
kubectl get -n kube-system daemonset.apps/aws-node --watch
# wait until UP-TO-DATE is 4
```

Confirm the proper credentials are in place.

```sh
kubectl exec -n kube-system $(kubectl get pods -n kube-system | grep aws-node | head -n 1 | awk '{print $1}') env | grep AWS
```

```
# Expected Output:
AWS_ROLE_ARN=arn:aws:iam::0123456789:role/demo-eks-oidc-test-aws-node
AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token 
AWS_VPC_K8S_CNI_LOGLEVEL=DEBUG 
```

Checking the pods again ...

```sh
$ k get pods -n kube-system
NAME                       READY   STATUS    RESTARTS   AGE
aws-node-7pqnl             1/1     Running   0          94s
aws-node-8cswp             1/1     Running   0          61s
aws-node-8vgk9             1/1     Running   0          2m55s
aws-node-x58c8             1/1     Running   0          2m12s
coredns-67b9c4d455-78tcz   1/1     Running   0          25m
coredns-67b9c4d455-mns85   1/1     Running   0          25m
kube-proxy-b42bt           1/1     Running   0          11m
kube-proxy-df8rg           1/1     Running   0          11m
kube-proxy-mccwn           1/1     Running   0          11m
kube-proxy-s8m8t           1/1     Running   0          11m
```

and we're good.



# Cleanup

```sh
terraform destroy -var-file=env_vars/test.tfvars
```

Manually remove the cloudWatch log group:  

```sh
aws logs delete-log-group --log-group-name demo-eks-oidc-test-vpc-flow-logs-cw-group
```

# References

The following links were used in the creation of this repository. 

* A good comparison on the existing alternatives https://www.bluematador.com/blog/iam-access-in-kubernetes-kube2iam-vs-kiam
* https://aws.amazon.com/blogs/opensource/introducing-fine-grained-iam-roles-service-accounts/
* https://medium.com/@marcincuber/amazon-eks-with-oidc-provider-iam-roles-for-kubernetes-services-accounts-59015d15cb0c
* https://github.com/mhausenblas/s3-echoer
* https://eksworkshop.com/irsa/deploy/

