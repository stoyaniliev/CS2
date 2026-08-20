
terraform {
  backend "s3" {
    bucket         = "innovatech-cs2-tfstate-33aed9c1"
    key            = "innovatech/main.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "innovatech-cs2-tflock"
    encrypt        = true
  }
}
