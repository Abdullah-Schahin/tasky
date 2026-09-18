resource "aws_ecr_repository" "tasky" {
  name                 = "${var.prefix}/tasky"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}
# No lifecycle rule deleting signed release evidence while the demo is being evaluated.
