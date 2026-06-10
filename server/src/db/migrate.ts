import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { closePool, pool } from "./pool.js";

const dirname = fileURLToPath(new URL(".", import.meta.url));
const migrationsDir = join(dirname, "migrations");

async function migrate(): Promise<void> {
  await pool.query(`
    create table if not exists schema_migrations (
      filename text primary key,
      applied_at timestamptz not null default now()
    )
  `);

  const files = (await readdir(migrationsDir))
    .filter((file) => file.endsWith(".sql"))
    .sort();

  for (const file of files) {
    const existing = await pool.query(
      `select 1 from schema_migrations where filename = $1`,
      [file],
    );

    if (existing.rowCount) {
      continue;
    }

    const sql = await readFile(join(migrationsDir, file), "utf8");

    await pool.query("begin");

    try {
      await pool.query(sql);
      await pool.query(`insert into schema_migrations (filename) values ($1)`, [
        file,
      ]);
      await pool.query("commit");
      console.log(`applied ${file}`);
    } catch (error) {
      await pool.query("rollback");
      throw error;
    }
  }
}

migrate()
  .then(closePool)
  .catch(async (error) => {
    console.error(error);
    await closePool();
    process.exit(1);
  });
