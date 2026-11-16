output "role_arn" {
  value = aws_iam_role.this.arn
}

output "role_name" {
  value = aws_iam_role.this.name
}

output "profile_arn" {
  value = aws_rolesanywhere_profile.this.arn
}
