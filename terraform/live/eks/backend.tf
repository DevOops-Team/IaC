# Backend settings (bucket · key · region) come from run.sh: the state bucket name includes the account ID.
terraform {
  backend "s3" {}
}
