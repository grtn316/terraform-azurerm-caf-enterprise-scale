# The following locals are used to extract the Policy Assignment
# configuration from the archetype module outputs.
locals {
  es_policy_assignments_by_management_group = flatten([
    for archetype in values(module.management_group_archetypes) :
    archetype.configuration.azurerm_policy_assignment
  ])
  es_policy_assignments_by_subscription = []
  es_policy_assignments = concat(
    local.es_policy_assignments_by_management_group,
    local.es_policy_assignments_by_subscription,
  )
}

# The following locals are used to build the map of Policy
# Assignments to deploy.
locals {
  azurerm_policy_assignment_enterprise_scale = {
    for assignment in local.es_policy_assignments :
    assignment.resource_id => assignment
  }
}

# To support the creation of Role Assignments for Policy Assignments
# using a Managed Identity, we need to identify the associated
# Role Definition(s) relating to the assigned Policy [Set] Definition
# within each Policy Assignment. This requires the following logic
# to determine which Role Assignments to create.

# Generate a list of internal Policy Definitions and Policy
# Set Definitions.
locals {
  internal_policy_definition_ids = [
    for policy_definition in local.es_policy_definitions :
    policy_definition.resource_id
  ]
  internal_policy_set_definition_ids = [
    for policy_set_definition in local.es_policy_set_definitions :
    policy_set_definition.resource_id
  ]
}

# Determine which Policy Assignments use a Managed Identity.
locals {
  policy_assignments_with_managed_identity = {
    for assignment in local.es_policy_assignments :
    assignment.resource_id => assignment.template.properties.policyDefinitionId
    if assignment.template.identity.type == "SystemAssigned"
  }
}

# Determine which of these Policy Assignments assign a Policy
# Definition or Policy Set Definition which is either built-in,
# or deployed to Azure using a process outside of this module.
locals {
  # Policy Definitions
  policy_assignments_with_managed_identity_using_external_policy_definition = {
    for policy_assignment_id, policy_definition_id in local.policy_assignments_with_managed_identity :
    policy_assignment_id => [
      policy_definition_id,
    ]
    if length(regexall(local.resource_types.policy_definition, policy_definition_id)) > 0
    && contains(local.internal_policy_definition_ids, policy_definition_id) != true
    && contains(keys(local.custom_policy_roles), policy_definition_id) != true
  }
  # Policy Set Definitions
  policy_assignments_with_managed_identity_using_external_policy_set_definition = {
    for policy_assignment_id, policy_set_definition_id in local.policy_assignments_with_managed_identity :
    policy_assignment_id => [
      policy_set_definition_id,
    ]
    if length(regexall(local.resource_types.policy_set_definition, policy_set_definition_id)) > 0
    && contains(local.internal_policy_set_definition_ids, policy_set_definition_id) != true
    && contains(keys(local.custom_policy_roles), policy_set_definition_id) != true
  }
}

# Generate list of Policy Set Definitions to lookup from Azure.
locals {
  azurerm_policy_set_definition_external_lookup = {
    for policy_set_definition_id in keys(transpose(local.policy_assignments_with_managed_identity_using_external_policy_set_definition)) :
    policy_set_definition_id => {
      name                  = basename(policy_set_definition_id)
      management_group_name = try(regex(local.regex_extract_provider_scope, policy_set_definition_id), null)
    }
  }
}

# Perform a lookup of the Policy Set Definitions not deployed by this module.
data "azurerm_policy_set_definition" "external_lookup" {
  for_each = local.azurerm_policy_set_definition_external_lookup

  name                  = each.value.name
  management_group_name = each.value.management_group_name
}

# Create a list of Policy Definitions IDs used by all assigned Policy Set Definitions
locals {
  policy_definition_ids_from_internal_policy_set_definitions = {
    for policy_set_definition in local.es_policy_set_definitions :
    policy_set_definition.resource_id => [
      for policy_definition in policy_set_definition.template.properties.policyDefinitions :
      policy_definition.policyDefinitionId
    ]
  }
  policy_definition_ids_from_external_policy_set_definitions = {
    for policy_set_definition_id, policy_set_definition_config in data.azurerm_policy_set_definition.external_lookup :
    policy_set_definition_id => [
      for policy_definition in policy_set_definition_config.policy_definition_reference :
      policy_definition.policy_definition_id
    ]
  }
  policy_definition_ids_from_policy_set_definitions = merge(
    local.policy_definition_ids_from_internal_policy_set_definitions,
    local.policy_definition_ids_from_external_policy_set_definitions,
  )
}

# Identify all Policy Definitions which are external to this module
locals {
  # From Policy Assignments using Policy Set Definitions
  external_policy_definition_ids_from_policy_set_definitions = distinct(flatten([
    for policy_definition_ids in values(local.policy_definition_ids_from_policy_set_definitions) : [
      for policy_definition_id in policy_definition_ids :
      policy_definition_id
      if contains(local.internal_policy_definition_ids, policy_definition_id) != true
    ]
  ]))
  external_policy_definitions_from_azurerm_policy_set_definition_external_lookup = {
    for policy_definition_id in local.external_policy_definition_ids_from_policy_set_definitions :
    policy_definition_id => {
      name                  = basename(policy_definition_id)
      management_group_name = try(regex(local.regex_extract_provider_scope, policy_definition_id), null)
    }
  }
  # From Policy Assignments using Policy Definitions
  external_policy_definitions_from_internal_policy_assignments = {
    for policy_definition_id in keys(transpose(local.policy_assignments_with_managed_identity_using_external_policy_definition)) :
    policy_definition_id => {
      name                  = basename(policy_definition_id)
      management_group_name = try(regex(local.regex_extract_provider_scope, policy_definition_id), null)
    }
  }
  # Then create a single list containing all Policy Definitions to lookup from Azure
  azurerm_policy_definition_external_lookup = merge(
    local.external_policy_definitions_from_azurerm_policy_set_definition_external_lookup,
    local.external_policy_definitions_from_internal_policy_assignments,
  )
}

# Perform a lookup of the Policy Definitions not deployed by this module.
data "azurerm_policy_definition" "external_lookup" {
  for_each = local.azurerm_policy_definition_external_lookup

  name                  = each.value.name
  management_group_name = each.value.management_group_name
}

# Extract the Role Definition IDs from the internal and external
# Policy Definitions, then combine into a single lookup map.
# Loop on list of roleDefinitionIds ensures correct character
# case to prevent duplicate values
locals {
  internal_policy_definition_roles = {
    for policy_definition in local.es_policy_definitions :
    policy_definition.resource_id => try(
      [
        for role_definition in policy_definition.template.properties.policyRule.then.details.roleDefinitionIds :
        "/providers/Microsoft.Authorization/roleDefinitions/${basename(role_definition)}"
      ],
      local.empty_list
    )
  }
  external_policy_definition_roles = {
    for policy_definition_id, policy_definition_config in data.azurerm_policy_definition.external_lookup :
    policy_definition_id => try(
      [
        for role_definition in jsondecode(policy_definition_config.policy_rule).then.details.roleDefinitionIds :
        "/providers/Microsoft.Authorization/roleDefinitions/${basename(role_definition)}"
      ],
      local.empty_list
    )
  }
  policy_definition_roles = merge(
    local.internal_policy_definition_roles,
    local.external_policy_definition_roles,
  )
}

# Merge the map of Policy Definitions from internal and
# external Policy Set Definitions then generate the map
# of roles for each.
locals {
  policy_set_definition_roles = {
    for policy_set_definition_id, policy_definition_ids in local.policy_definition_ids_from_policy_set_definitions :
    policy_set_definition_id => distinct(flatten([
      for policy_definition_id in policy_definition_ids :
      local.policy_definition_roles[policy_definition_id]
    ]))
  }
}

# Merge the map of roles for Policy Definitions and
# Policy Set Definitions.
locals {
  policy_roles = merge(
    local.policy_definition_roles,
    local.policy_set_definition_roles,
  )
}

# Construct the array used to determine the list of
# Role Assignments to create for the Managed Identities
# used by Policy Assignments.
# The "identity" object is an array containing a single
# identity item.
# The try() logic below is to prevent errors when running
# 'terraform destroy'.
locals {
  es_role_assignments_by_policy_assignment = flatten([
    for policy_assignment_id, policy_id in local.policy_assignments_with_managed_identity : [
      for role_definition_id in try(local.policy_roles[policy_id], local.empty_list) : [
        {
          resource_id          = "${local.azurerm_policy_assignment_enterprise_scale[policy_assignment_id].scope_id}${local.provider_path.role_assignment}${uuidv5(uuidv5("url", role_definition_id), policy_assignment_id)}"
          scope_id             = local.azurerm_policy_assignment_enterprise_scale[policy_assignment_id].scope_id
          principal_id         = try(azurerm_policy_assignment.enterprise_scale[policy_assignment_id].identity[0].principal_id, null)
          role_definition_name = null
          role_definition_id   = role_definition_id
        }
      ]
    ]
  ])
}
