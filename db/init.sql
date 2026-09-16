-- Runs automatically the FIRST time the database volume is created.
-- If you change this file, you must `docker compose down -v` to see the effect,
-- because Postgres skips this script when the data directory already exists.

CREATE TABLE IF NOT EXISTS tasks (
    id         SERIAL PRIMARY KEY,
    title      VARCHAR(200) NOT NULL,
    done       BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Queries filter and sort on these, so index them.
CREATE INDEX IF NOT EXISTS idx_tasks_done       ON tasks (done);
CREATE INDEX IF NOT EXISTS idx_tasks_created_at ON tasks (created_at DESC);

INSERT INTO tasks (title, done) VALUES
    ('Learn the Linux command line', TRUE),
    ('Understand Docker images vs containers', TRUE),
    ('Build a CI/CD pipeline', FALSE),
    ('Deploy a three-tier app', FALSE)
ON CONFLICT DO NOTHING;
