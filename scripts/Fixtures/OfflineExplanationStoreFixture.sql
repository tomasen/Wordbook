PRAGMA application_id = 1463960400;
PRAGMA user_version = 1;

CREATE TABLE metadata (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE sense (
    sense_id TEXT PRIMARY KEY NOT NULL,
    lemma TEXT NOT NULL,
    normalized_lemma TEXT NOT NULL,
    part_of_speech TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE explanation (
    explanation_id TEXT PRIMARY KEY NOT NULL,
    sense_id TEXT NOT NULL UNIQUE REFERENCES sense(sense_id),
    content_hash TEXT NOT NULL,
    schema_version INTEGER NOT NULL,
    meaning TEXT NOT NULL,
    example TEXT NOT NULL,
    memory_technique TEXT,
    memory_aid_json TEXT NOT NULL,
    synonyms_json TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE word_form (
    normalized_form TEXT NOT NULL,
    sense_id TEXT NOT NULL REFERENCES sense(sense_id),
    display_form TEXT NOT NULL,
    morphology_json TEXT NOT NULL,
    rank INTEGER NOT NULL CHECK (rank >= 0),
    PRIMARY KEY (normalized_form, sense_id)
) WITHOUT ROWID;

CREATE INDEX word_form_sense_idx
    ON word_form (sense_id, normalized_form);

CREATE TABLE form_default (
    normalized_form TEXT PRIMARY KEY NOT NULL,
    sense_id TEXT NOT NULL REFERENCES sense(sense_id)
) WITHOUT ROWID;

CREATE TABLE book_membership (
    sense_id TEXT NOT NULL REFERENCES sense(sense_id),
    book_tag TEXT NOT NULL,
    PRIMARY KEY (sense_id, book_tag)
) WITHOUT ROWID;

INSERT INTO metadata (key, value) VALUES
    ('content_version', 'fixture-v1');

INSERT INTO sense (sense_id, lemma, normalized_lemma, part_of_speech) VALUES
    ('wn:go:v:1', 'go', 'go', 'v'),
    ('wn:saw:v:1', 'see', 'see', 'v'),
    ('wn:saw:n:1', 'saw', 'saw', 'n'),
    ('wn:left:v:1', 'leave', 'leave', 'v'),
    ('wn:left:n:1', 'left', 'left', 'n');

INSERT INTO explanation (
    explanation_id,
    sense_id,
    content_hash,
    schema_version,
    meaning,
    example,
    memory_technique,
    memory_aid_json,
    synonyms_json
) VALUES
    (
        'exp:go:v:1',
        'wn:go:v:1',
        'fixture-hash-go',
        1,
        'to move or travel from one place to another',
        'She went home before sunset.',
        'contrast',
        '["Go is present; went points to the same action in the past."]',
        '["travel","move"]'
    ),
    (
        'exp:saw:v:1',
        'wn:saw:v:1',
        'fixture-hash-saw-verb',
        1,
        'noticed something with your eyes in the past',
        'We saw the comet last night.',
        NULL,
        '[]',
        '["noticed","observed"]'
    ),
    (
        'exp:saw:n:1',
        'wn:saw:n:1',
        'fixture-hash-saw-noun',
        1,
        'a toothed tool used for cutting hard material',
        'The carpenter reached for a saw.',
        'image',
        '["Picture the row of sharp teeth along its edge."]',
        '["cutting tool"]'
    ),
    (
        'exp:left:v:1',
        'wn:left:v:1',
        'fixture-hash-left-verb',
        1,
        'went away from a place in the past',
        'They left shortly after lunch.',
        NULL,
        '[]',
        '["departed"]'
    ),
    (
        'exp:left:n:1',
        'wn:left:n:1',
        'fixture-hash-left-noun',
        1,
        'the side opposite right',
        'The library is on your left.',
        NULL,
        '[]',
        '[]'
    );

INSERT INTO word_form (
    normalized_form,
    sense_id,
    display_form,
    morphology_json,
    rank
) VALUES
    ('go', 'wn:go:v:1', 'go', '"lemma"', 0),
    ('went', 'wn:go:v:1', 'went', '"past"', 0),
    ('saw', 'wn:saw:v:1', 'saw', '"past"', 0),
    ('saw', 'wn:saw:n:1', 'saw', '"lemma"', 1),
    ('left', 'wn:left:v:1', 'left', '["past","pastParticiple"]', 0),
    ('left', 'wn:left:n:1', 'left', '"lemma"', 1);

INSERT INTO form_default (normalized_form, sense_id) VALUES
    ('go', 'wn:go:v:1'),
    ('went', 'wn:go:v:1'),
    ('saw', 'wn:saw:v:1'),
    ('left', 'wn:left:v:1');

INSERT INTO book_membership (sense_id, book_tag) VALUES
    ('wn:go:v:1', 'fixture'),
    ('wn:saw:v:1', 'fixture'),
    ('wn:saw:n:1', 'fixture'),
    ('wn:left:v:1', 'fixture'),
    ('wn:left:n:1', 'fixture');
