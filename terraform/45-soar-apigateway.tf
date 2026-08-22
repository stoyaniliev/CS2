# ---------------------------------------------------------------------------
# Private API Gateway: the SOAR ingest endpoint (REQ-NCA-P2-03)
#
# endpoint_type = PRIVATE means this API has no public DNS name and no route
# from the internet. It is reachable only through the interface VPC endpoint
# below, and the resource policy rejects any request that did not arrive via
# that endpoint — so even a leaked URL is useless from outside.
#
# The endpoint sits in the hub, which every alert source can already reach:
#   - k3s Alertmanager, from the platform spoke over the Transit Gateway
#   - on-premises rsyslog, over the Tailscale tunnel into the hub
# ---------------------------------------------------------------------------

resource "aws_security_group" "api_endpoint" {
  name        = "${var.project}-api-endpoint"
  description = "HTTPS to the private SOAR ingest API"
  vpc_id      = aws_vpc.hub.id

  ingress {
    description = "HTTPS from the cloud networks and from on-premises"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.hub_cidr, var.platform_cidr, var.data_cidr, var.onprem_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-api-endpoint-sg" }
}

resource "aws_vpc_endpoint" "execute_api" {
  vpc_id              = aws_vpc.hub.id
  service_name        = "com.amazonaws.${var.region}.execute-api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.hub_private[*].id
  security_group_ids  = [aws_security_group.api_endpoint.id]
  private_dns_enabled = true

  tags = { Name = "${var.project}-execute-api-endpoint" }
}

resource "aws_api_gateway_rest_api" "soar" {
  name        = "${var.project}-soar-ingest"
  description = "Private ingest endpoint for security events"

  endpoint_configuration {
    types = ["PRIVATE"]
    vpc_endpoint_ids = [
      aws_vpc_endpoint.execute_api.id,
      aws_vpc_endpoint.execute_api_platform.id,
    ]
  }

  tags = { Component = "soar" }
}

# Defence in depth: IAM-independent rejection of anything not arriving through
# our own endpoint.
resource "aws_api_gateway_rest_api_policy" "soar" {
  rest_api_id = aws_api_gateway_rest_api.soar.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "execute-api:Invoke"
        Resource  = "${aws_api_gateway_rest_api.soar.execution_arn}/*"
      },
      {
        Effect    = "Deny"
        Principal = "*"
        Action    = "execute-api:Invoke"
        Resource  = "${aws_api_gateway_rest_api.soar.execution_arn}/*"
        Condition = {
          StringNotEquals = {
            "aws:SourceVpce" = [
              aws_vpc_endpoint.execute_api.id,
              aws_vpc_endpoint.execute_api_platform.id,
            ]
          }
        }
      },
    ]
  })
}

resource "aws_api_gateway_resource" "events" {
  rest_api_id = aws_api_gateway_rest_api.soar.id
  parent_id   = aws_api_gateway_rest_api.soar.root_resource_id
  path_part   = "events"
}

resource "aws_api_gateway_method" "post_events" {
  rest_api_id   = aws_api_gateway_rest_api.soar.id
  resource_id   = aws_api_gateway_resource.events.id
  http_method   = "POST"
  authorization = "NONE" # network-level control; see the resource policy above
}

resource "aws_api_gateway_integration" "collector" {
  rest_api_id             = aws_api_gateway_rest_api.soar.id
  resource_id             = aws_api_gateway_resource.events.id
  http_method             = aws_api_gateway_method.post_events.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.collector.invoke_arn
}

resource "aws_lambda_permission" "api_collector" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.collector.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.soar.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "soar" {
  rest_api_id = aws_api_gateway_rest_api.soar.id

  # Forces a redeployment whenever the API shape changes; without this,
  # Terraform updates the definition but never publishes it.
  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.events.id,
      aws_api_gateway_method.post_events.id,
      aws_api_gateway_integration.collector.id,
      aws_api_gateway_rest_api_policy.soar.policy,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.soar.id
  rest_api_id   = aws_api_gateway_rest_api.soar.id
  stage_name    = "prod"

  tags = { Component = "soar" }
}

resource "aws_api_gateway_method_settings" "prod" {
  rest_api_id = aws_api_gateway_rest_api.soar.id
  stage_name  = aws_api_gateway_stage.prod.stage_name
  method_path = "*/*"

   # The account-level CloudWatch role must exist before a stage can enable
  # execution logging. No attribute links them, so the dependency is declared.
  depends_on = [aws_api_gateway_account.main]

  settings {
    metrics_enabled = true
    logging_level   = "INFO"
  }
}

output "soar_ingest_url" {
  description = "POST security events here. Resolvable only inside the VPCs and from on-prem."
  value       = "https://${aws_api_gateway_rest_api.soar.id}.execute-api.${var.region}.amazonaws.com/prod/events"
}

output "soar_event_bus" {
  value = aws_cloudwatch_event_bus.soar.name
}

# ---------------------------------------------------------------------------
# API Gateway execution logging.
#
# The CloudWatch role is an account-level setting, not a per-API one, so it is
# declared once here. Note this is shared account state: it affects every API
# Gateway in the account, which is worth flagging in a shared environment.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "apigw_cloudwatch" {
  name = "${var.project}-apigw-cloudwatch"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "apigw_cloudwatch" {
  role       = aws_iam_role.apigw_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch.arn
}

# ---------------------------------------------------------------------------
# Second execute-api endpoint, in the platform spoke.
#
# An interface endpoint's private DNS only resolves inside the VPC that hosts
# it. Alertmanager runs on k3s in the platform spoke, so without this it would
# resolve the ingest URL to a public address, follow the default route out
# through the NAT gateway, and be rejected by the API's resource policy for not
# arriving via a VPC endpoint.
#
# The alternative is a customer-managed private hosted zone for
# execute-api.<region>.amazonaws.com associated with every spoke, aliased to
# the hub endpoint. That scales better across many spokes and is the right
# answer at production size; a second endpoint is simpler to reason about at
# this one and costs roughly EUR 7/month.
# ---------------------------------------------------------------------------

resource "aws_security_group" "api_endpoint_platform" {
  name        = "${var.project}-api-endpoint-platform"
  description = "HTTPS to the private SOAR ingest API from the platform spoke"
  vpc_id      = module.platform_spoke.vpc_id

  ingress {
    description = "HTTPS from workloads in the platform spoke"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.platform_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-api-endpoint-platform-sg" }
}

resource "aws_vpc_endpoint" "execute_api_platform" {
  vpc_id              = module.platform_spoke.vpc_id
  service_name        = "com.amazonaws.${var.region}.execute-api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.platform_spoke.private_subnet_ids
  security_group_ids  = [aws_security_group.api_endpoint_platform.id]
  private_dns_enabled = true

  tags = { Name = "${var.project}-execute-api-endpoint-platform" }
}
