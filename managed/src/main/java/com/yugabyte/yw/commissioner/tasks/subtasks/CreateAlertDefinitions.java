// Copyright (c) YugaByte, Inc.

package com.yugabyte.yw.commissioner.tasks.subtasks;

import com.yugabyte.yw.commissioner.tasks.UniverseTaskBase;
import com.yugabyte.yw.common.AlertDefinitionTemplate;
import com.yugabyte.yw.common.alerts.AlertDefinitionLabelsBuilder;
import com.yugabyte.yw.forms.UniverseTaskParams;
import com.yugabyte.yw.models.AlertDefinition;
import com.yugabyte.yw.models.Customer;
import com.yugabyte.yw.models.Universe;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class CreateAlertDefinitions extends UniverseTaskBase {
  public static final Logger LOG = LoggerFactory.getLogger(CreateAlertDefinitions.class);

  protected UniverseTaskParams taskParams() {
    return (UniverseTaskParams) taskParams;
  }

  @Override
  public String getName() {
    return super.getName() + "(" + taskParams().universeUUID + ")";
  }

  @Override
  public void run() {
    try {
      LOG.info("Running {}", getName());
      Universe universe = Universe.getOrBadRequest(taskParams().universeUUID);
      Customer customer = Customer.get(universe.customerId);
      String nodePrefix = universe.getUniverseDetails().nodePrefix;

      for (AlertDefinitionTemplate definition : AlertDefinitionTemplate.values()) {
        if (definition.isCreateForNewUniverse()) {
          AlertDefinition.create(customer.uuid, AlertDefinition.TargetType.Universe,
            definition.getName(), definition.buildTemplate(nodePrefix), true,
            AlertDefinitionLabelsBuilder.create().appendUniverse(universe).get());
        }
      }

    } catch (Exception e) {
      String msg = getName() + " failed with exception " + e.getMessage();
      LOG.warn(msg, e.getMessage());
      throw new RuntimeException(msg, e);
    }
  }
}
