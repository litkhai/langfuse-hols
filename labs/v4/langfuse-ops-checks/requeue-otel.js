// requeue-otel.js — put raw OTLP files back on the OTel ingestion queue, with their full blob key.
// Runs inside the worker container (it uses the worker's own @langfuse/shared and Redis settings):
//   docker exec -i <worker> sh -c 'cd /app/worker && node - <project_id> <full key> [...]' < requeue-otel.js
// The job has the shape the web's OtelIngestionProcessor.publishToOtelIngestionQueue enqueues. Used by
// 03c-reconcile.sh because POST /api/admin/ingestion-replay of 4.56.0 cannot replay OTel files when
// LANGFUSE_S3_EVENT_UPLOAD_PREFIX is set (README, test 03).
const { randomUUID } = require("crypto");
const { OtelIngestionQueue, QueueJobs } = require("@langfuse/shared/src/server");
const [projectId, ...keys] = process.argv.slice(2);
(async () => {
  for (const fileKey of keys) {
    const q = OtelIngestionQueue.getInstance({ shardingKey: `${projectId}-${fileKey}` });
    await q.add(QueueJobs.OtelIngestionJob, {
      id: randomUUID(), timestamp: new Date(), name: QueueJobs.OtelIngestionJob,
      payload: { data: { fileKey, publicKey: "" },
                 authCheck: { validKey: true, scope: { projectId, accessLevel: "project" } } },
    });
  }
  console.log(JSON.stringify({ queued: keys.length }));
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
