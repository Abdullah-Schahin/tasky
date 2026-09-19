data "aws_iam_role" "cluster_setup" { name = "${var.prefix}-ci-cluster" }
resource "aws_eks_access_entry" "cluster_setup" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_iam_role.cluster_setup.arn
  type          = "STANDARD"
}
resource "aws_eks_access_policy_association" "cluster_setup" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.cluster_setup.principal_arn
  policy_arn    = "${local.aws_prefix}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}
resource "aws_iam_role_policy_attachment" "mongodb_ssm" {
  role       = aws_iam_role.mongodb.name
  policy_arn = "${local.aws_prefix}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
# No arbitrary shell parameters: only return the public CA after successful bootstrap.
resource "aws_ssm_document" "mongodb_ca" {
  name          = "${var.prefix}-mongodb-ca"
  document_type = "Command"
  content = jsonencode({ schemaVersion = "2.2", mainSteps = [{
    action = "aws:runShellScript", name = "ReadPublicCA", inputs = {
      runCommand = ["set -eu", "test -f /var/lib/tasky-backup/bootstrap-complete", "systemctl is-active --quiet mongod", "cat /etc/mongodb/tls/ca.crt"]
    }
  }] })
}
output "cluster_setup" {
  value = {
    role            = data.aws_iam_role.cluster_setup.arn
    cluster         = aws_eks_cluster.main.name
    region          = var.region
    vpc             = aws_vpc.main.id
    controller_role = aws_iam_role.load_balancer_controller.arn
    mongo_instance  = aws_instance.mongodb.id
    mongo_ip        = aws_instance.mongodb.private_ip
    mongo_secret    = local.mongodb_secret_arn
    ca_document     = aws_ssm_document.mongodb_ca.name
  }
}
