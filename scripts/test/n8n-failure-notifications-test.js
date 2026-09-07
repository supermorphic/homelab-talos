#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');

const workflowPath = process.argv[2];
if (!workflowPath) throw new Error('workflow path is required');

const workflow = JSON.parse(fs.readFileSync(workflowPath, 'utf8'));
const formatterCode = workflow.nodes.find((node) => node.name === 'Format Failure Notification')
  ?.parameters?.jsCode;
if (!formatterCode) throw new Error('Format Failure Notification code is missing');

const NativeDate = Date;
const detectedAt = '2026-09-07T16:30:00.000Z';
class FixedDate extends NativeDate {
  constructor(...args) {
    super(args.length === 0 ? detectedAt : args[0]);
  }

  static now() {
    return NativeDate.parse(detectedAt);
  }

  static parse(value) {
    return NativeDate.parse(value);
  }
}

const format = new Function('$input', 'Date', formatterCode);
const execute = (items) => format({ all: () => items }, FixedDate);
const outputJson = (input) => {
  const result = execute([{ json: input }]);
  assert.equal(result.length, 1);
  return result[0].json;
};

const sensitiveValues = [
  'SYNTHETIC_SENSITIVE_MARKER_ONE_DO_NOT_PUBLISH',
  'secret-provider-response',
  'secret-stack-frame',
  'secret-error-context',
  'secret-webhook-payload',
];
const executionNotification = outputJson({
  workflow: { id: 'Abc_123-xyz', name: 'Nightly Intake' },
  execution: {
    id: '12345',
    lastNodeExecuted: 'Store Result',
    mode: 'webhook',
    error: {
      message: sensitiveValues[0],
      description: sensitiveValues[1],
      stack: sensitiveValues[2],
      context: { value: sensitiveValues[3] },
      timestamp: NativeDate.parse('2026-09-07T16:00:00.000Z'),
    },
    executionContext: { payload: sensitiveValues[4] },
  },
  request: { body: { marker: sensitiveValues[4] } },
});
assert.deepEqual(executionNotification, {
  topic: 'homelab',
  title: 'n8n workflow failed',
  priority: 3,
  message:
    'Automatic workflow execution failed.\n' +
    'Workflow: Nightly Intake\n' +
    'Node: Store Result\n' +
    'Execution: 12345\n' +
    'Failed at: 2026-09-07T16:00:00.000Z',
  click: 'https://n8n.lab.supermorphic.com/workflow/Abc_123-xyz/executions/12345',
});
const serializedExecutionNotification = JSON.stringify(executionNotification);
for (const value of sensitiveValues) {
  assert.equal(serializedExecutionNotification.includes(value), false, `formatter copied ${value}`);
}

const triggerNotification = outputJson({
  workflow: { id: 'trigger_workflow', name: 'Schedule Watch' },
  trigger: {
    mode: 'trigger',
    error: {
      message: 'secret-trigger-message',
      stack: 'secret-trigger-stack',
      timestamp: '2026-09-07T15:45:00.000Z',
    },
  },
});
assert.deepEqual(triggerNotification, {
  topic: 'homelab',
  title: 'n8n workflow failed',
  priority: 3,
  message:
    'Automatic workflow trigger failed.\n' +
    'Workflow: Schedule Watch\n' +
    'Node: trigger\n' +
    'Execution: unavailable\n' +
    'Failed at: 2026-09-07T15:45:00.000Z',
});
assert.equal(JSON.stringify(triggerNotification).includes('secret-trigger'), false);

const hostileNotification = outputJson({
  workflow: {
    id: '../private/workflow',
    name: '  Workflow\n\twith\u0000 controls   and a name that is deliberately much too long  ',
  },
  execution: {
    id: '12345\n678',
    lastNodeExecuted: '  Node\r\n\twith controls and a deliberately excessive suffix  ',
    error: {
      message: 'raw-message-must-stay-private',
      timestamp: 'not-a-timestamp',
    },
  },
});
assert.deepEqual(hostileNotification, {
  topic: 'homelab',
  title: 'n8n workflow failed',
  priority: 3,
  message:
    'Automatic workflow execution failed.\n' +
    'Workflow: Workflow with controls and a name that i\n' +
    'Node: Node with controls and a deliberately ex\n' +
    'Execution: unavailable\n' +
    'Detected at: 2026-09-07T16:30:00.000Z',
});
assert.equal(Buffer.byteLength(hostileNotification.message, 'utf8') <= 512, true);
assert.equal(hostileNotification.message.includes('raw-message-must-stay-private'), false);

const unicodeNotification = outputJson({
  workflow: { id: 'unicode_workflow', name: '🔒'.repeat(80) },
  execution: {
    id: 9,
    lastNodeExecuted: '🧪'.repeat(80),
    error: { timestamp: 1788796800000 },
  },
});
assert.equal(Array.from(unicodeNotification.message.match(/^Workflow: (.*)$/m)[1]).length, 40);
assert.equal(Array.from(unicodeNotification.message.match(/^Node: (.*)$/m)[1]).length, 40);
assert.equal(Buffer.byteLength(unicodeNotification.message, 'utf8') <= 512, true);
assert.equal(unicodeNotification.click.endsWith('/executions/9'), true);

for (const items of [[], [{ json: {} }, { json: {} }]]) {
  assert.throws(() => execute(items), /failure_event_item_count_invalid/);
}
for (const input of [
  {},
  { workflow: { id: 'wf', name: 'Both' }, execution: {}, trigger: {} },
  { workflow: { id: 'wf', name: 'Bad execution' }, execution: null },
  { workflow: null, execution: {} },
]) {
  assert.throws(() => outputJson(input), /failure_event_shape_invalid/);
}
