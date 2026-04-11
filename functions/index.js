'use strict';

// firebase-functions v2 API — requires firebase-functions >= 4.0.0
const { onValueWritten } = require('firebase-functions/v2/database');
const admin = require('firebase-admin');

admin.initializeApp();

/**
 * processCloudIAQ
 *
 * Triggers whenever a new record is written to /readings/{nodeId}/{recordId}.
 * Only acts on mode === "cloud" records.
 *
 * 1. Queries the 6 most-recent siblings ordered by gateway_receive_time.
 * 2. Excludes the current record to avoid double-counting.
 * 3. Takes up to 5 previous cloud records; pads missing slots with 400 ppm.
 * 4. Calculates moving average, IAQ score, and alert level.
 * 5. Writes results back with update() — never overwrites original sensor data.
 */
exports.processCloudIAQ = onValueWritten(
  {
    ref: '/readings/{nodeId}/{recordId}',
    region: 'us-central1',
  },
  async (event) => {
    // onValueWritten fires on create AND update (including our own write-back).
    // Guard: only run on initial record creation (before.exists() === false).
    // This prevents the infinite loop that would occur when our update()
    // call triggers another onValueWritten invocation.
    if (event.data.before.exists()) return null;

    // After the guard, treat this as a create event — read the new data.
    const data = event.data.after.val();

    // Only process cloud-mode records
    if (!data || data.mode !== 'cloud') return null;

    const functionStart = Date.now();
    const { nodeId, recordId } = event.params;

    // ── Query siblings ──────────────────────────────────────────────────────
    // limitToLast(6): the 6 records with the highest gateway_receive_time.
    // The current record will be the last entry (highest receive time).
    // After excluding it, we have at most 5 previous records.
    const snapshot = await admin
      .database()
      .ref(`/readings/${nodeId}`)
      .orderByChild('gateway_receive_time')
      .limitToLast(6)
      .once('value');

    // ── Collect co2 values from previous cloud records ──────────────────────
    // forEach iterates in ascending order of gateway_receive_time.
    const co2Values = [];
    snapshot.forEach((child) => {
      if (child.key === recordId) return; // exclude current record
      const record = child.val();
      if (record && record.mode === 'cloud' && typeof record.co2 === 'number') {
        co2Values.push(record.co2);
      }
    });

    // ── Pad to exactly 5 values ─────────────────────────────────────────────
    // Pad the front (oldest slots) with 400 ppm (clean-air baseline).
    const padded = [...co2Values];
    while (padded.length < 5) padded.unshift(400);

    const cloudBufferReady = co2Values.length === 5;

    // ── IAQ calculations ────────────────────────────────────────────────────
    const movingAvg = padded.reduce((sum, v) => sum + v, 0) / 5;
    const temp = typeof data.temp === 'number' ? data.temp : 22.0;
    const cloudIaqScore = movingAvg + (temp - 22.0) * 0.5;
    const cloudAlert = cloudIaqScore > 1000 ? 'OPEN_WINDOW' : 'NORMAL';

    const functionEnd = Date.now();
    const cloudProcessingMs = functionEnd - functionStart;

    // ── Write-back — update() only, never set() ─────────────────────────────
    await admin
      .database()
      .ref(`/readings/${nodeId}/${recordId}`)
      .update({
        cloud_iaq_moving_avg: movingAvg,
        cloud_iaq_score: cloudIaqScore,
        cloud_alert: cloudAlert,
        cloud_buffer_ready: cloudBufferReady,
        cloud_processing_ms: cloudProcessingMs,
        function_completed_at: Date.now(),
      });

    console.log(
      `[processCloudIAQ] node=${nodeId} record=${recordId} ` +
        `score=${cloudIaqScore.toFixed(1)} alert=${cloudAlert} ` +
        `bufferReady=${cloudBufferReady} processingMs=${cloudProcessingMs}`
    );

    return null;
  }
);
