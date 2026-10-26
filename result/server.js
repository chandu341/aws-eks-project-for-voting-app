const express = require('express');
const { Pool } = require('pg');
const path = require('path');

const app = express();
const port = process.env.PORT || 80;

const pool = new Pool({
  host: process.env.DB_HOST || 'db',
  port: parseInt(process.env.DB_PORT || '5432'),
  user: process.env.POSTGRES_USER || 'postgres',
  password: process.env.POSTGRES_PASSWORD || 'postgres',
  database: process.env.POSTGRES_DB || 'postgres',
  connectionTimeoutMillis: 5000,
});

// Auto-initialize votes table if not already present
async function initDb() {
  let connected = false;
  while (!connected) {
    try {
      await pool.query(`
        CREATE TABLE IF NOT EXISTS votes (
          id VARCHAR(255) NOT NULL UNIQUE,
          vote VARCHAR(255) NOT NULL
        )
      `);
      console.log('Connected to PostgreSQL and verified votes table.');
      connected = true;
    } catch (err) {
      console.log('Waiting for PostgreSQL to be ready...', err.message);
      await new Promise((res) => setTimeout(res, 2000));
    }
  }
}
initDb();

app.use(express.static(path.join(__dirname, 'views')));

app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy', service: 'result-dashboard' });
});

app.get('/api/votes', async (req, res) => {
  try {
    const result = await pool.query('SELECT vote, count(id) AS count FROM votes GROUP BY vote');
    let aCount = 0;
    let bCount = 0;

    result.rows.forEach((row) => {
      if (row.vote === 'a') aCount = parseInt(row.count, 10);
      if (row.vote === 'b') bCount = parseInt(row.count, 10);
    });

    const total = aCount + bCount;
    const aPercent = total > 0 ? Math.round((aCount / total) * 100) : 50;
    const bPercent = total > 0 ? (100 - aPercent) : 50;

    res.json({
      a: aCount,
      b: bCount,
      total: total,
      aPercent: aPercent,
      bPercent: bPercent,
    });
  } catch (err) {
    console.error('Error fetching votes:', err.message);
    res.status(500).json({ error: 'Database unavailable' });
  }
});

app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'index.html'));
});

app.listen(port, '0.0.0.0', () => {
  console.log(`Results dashboard running on port ${port}`);
});
