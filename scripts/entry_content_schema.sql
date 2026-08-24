PRAGMA application_id = 1463960400;
PRAGMA user_version = 2;

CREATE TABLE metadata (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE word_entry (
    entry_id TEXT PRIMARY KEY NOT NULL,
    language_tag TEXT NOT NULL,
    normalized_form TEXT NOT NULL,
    display_form TEXT NOT NULL,
    normalization_version INTEGER NOT NULL CHECK (normalization_version > 0),
    entry_revision INTEGER NOT NULL CHECK (entry_revision > 0),
    entry_rank INTEGER NOT NULL CHECK (entry_rank >= 0),
    UNIQUE (language_tag, normalized_form, normalization_version),
    UNIQUE (entry_id, language_tag, normalized_form)
) WITHOUT ROWID;

CREATE TABLE entry_usage (
    entry_usage_id TEXT PRIMARY KEY NOT NULL,
    entry_id TEXT NOT NULL,
    language_tag TEXT NOT NULL,
    normalized_form TEXT NOT NULL,
    part_of_speech_label TEXT,
    learner_label TEXT,
    pronunciation_json TEXT NOT NULL,
    form_relation_label TEXT,
    context_vector_format_version INTEGER,
    context_vector BLOB,
    display_order INTEGER NOT NULL CHECK (display_order >= 0),
    commonness_rank INTEGER NOT NULL CHECK (commonness_rank > 0),
    is_core INTEGER NOT NULL CHECK (is_core IN (0, 1)),
    FOREIGN KEY (entry_id, language_tag, normalized_form)
        REFERENCES word_entry(entry_id, language_tag, normalized_form),
    UNIQUE (entry_id, entry_usage_id),
    UNIQUE (entry_id, display_order),
    CHECK (
        (context_vector_format_version IS NULL AND context_vector IS NULL)
        OR
        (context_vector_format_version > 0 AND context_vector IS NOT NULL)
    )
);

CREATE TABLE released_lesson_variant (
    explanation_id TEXT PRIMARY KEY NOT NULL,
    entry_id TEXT NOT NULL,
    entry_usage_id TEXT NOT NULL,
    locale TEXT NOT NULL,
    schema_version INTEGER NOT NULL CHECK (schema_version > 0),
    lesson_contract_version INTEGER NOT NULL CHECK (lesson_contract_version > 0),
    validator_version INTEGER NOT NULL CHECK (validator_version > 0),
    review_policy_version INTEGER NOT NULL CHECK (review_policy_version > 0),
    content_revision INTEGER NOT NULL CHECK (content_revision > 0),
    content_hash TEXT NOT NULL,
    direct_explanation TEXT NOT NULL,
    example TEXT NOT NULL,
    synonyms_json TEXT NOT NULL,
    memory_cue_json TEXT,
    trust_state TEXT NOT NULL CHECK (trust_state = 'releaseReviewed'),
    FOREIGN KEY (entry_id, entry_usage_id)
        REFERENCES entry_usage(entry_id, entry_usage_id),
    UNIQUE (entry_id, entry_usage_id, locale, content_revision),
    UNIQUE (explanation_id, entry_id, entry_usage_id, locale)
);

CREATE TABLE entry_default (
    entry_id TEXT NOT NULL,
    entry_usage_id TEXT NOT NULL,
    locale TEXT NOT NULL,
    explanation_id TEXT NOT NULL,
    FOREIGN KEY (entry_id, entry_usage_id)
        REFERENCES entry_usage(entry_id, entry_usage_id),
    FOREIGN KEY (explanation_id, entry_id, entry_usage_id, locale)
        REFERENCES released_lesson_variant(
            explanation_id, entry_id, entry_usage_id, locale
        ),
    PRIMARY KEY (entry_id, entry_usage_id, locale)
) WITHOUT ROWID;

CREATE TABLE entry_coverage (
    entry_id TEXT NOT NULL,
    locale TEXT NOT NULL,
    coverage_revision INTEGER NOT NULL CHECK (coverage_revision > 0),
    expected_usage_count INTEGER NOT NULL CHECK (expected_usage_count > 0),
    expected_core_count INTEGER NOT NULL
        CHECK (expected_core_count BETWEEN 1 AND 4),
    available_usage_count INTEGER NOT NULL,
    has_more_usages INTEGER NOT NULL CHECK (has_more_usages IN (0, 1)),
    coverage_state TEXT NOT NULL
        CHECK (coverage_state = 'releaseReviewedComplete'),
    content_version TEXT NOT NULL,
    usage_selection_policy_version INTEGER NOT NULL CHECK (
        usage_selection_policy_version > 0
    ),
    lesson_contract_version INTEGER NOT NULL CHECK (lesson_contract_version > 0),
    validator_version INTEGER NOT NULL CHECK (validator_version > 0),
    review_policy_version INTEGER NOT NULL CHECK (review_policy_version > 0),
    PRIMARY KEY (entry_id, locale),
    FOREIGN KEY (entry_id) REFERENCES word_entry(entry_id),
    CHECK (expected_usage_count >= expected_core_count),
    CHECK (available_usage_count = expected_usage_count),
    CHECK (
        (has_more_usages = 1 AND expected_usage_count > expected_core_count)
        OR
        (has_more_usages = 0 AND expected_usage_count = expected_core_count)
    )
) WITHOUT ROWID;

CREATE TABLE entry_migration (
    release_sequence INTEGER NOT NULL CHECK (release_sequence > 0),
    old_entry_id TEXT NOT NULL,
    old_language_tag TEXT NOT NULL,
    old_normalized_form TEXT NOT NULL,
    new_entry_id TEXT NOT NULL,
    reason_code TEXT NOT NULL,
    FOREIGN KEY (new_entry_id) REFERENCES word_entry(entry_id),
    PRIMARY KEY (release_sequence, old_entry_id),
    UNIQUE (release_sequence, old_entry_id, new_entry_id)
) WITHOUT ROWID;

CREATE TABLE entry_usage_disposition (
    release_sequence INTEGER NOT NULL CHECK (release_sequence > 0),
    old_entry_id TEXT NOT NULL,
    old_entry_usage_id TEXT NOT NULL,
    disposition TEXT NOT NULL CHECK (disposition IN ('redirected', 'retired')),
    new_entry_id TEXT,
    new_entry_usage_id TEXT,
    migration_release_sequence INTEGER,
    reason_code TEXT NOT NULL,
    FOREIGN KEY (new_entry_id, new_entry_usage_id)
        REFERENCES entry_usage(entry_id, entry_usage_id),
    FOREIGN KEY (migration_release_sequence, old_entry_id, new_entry_id)
        REFERENCES entry_migration(release_sequence, old_entry_id, new_entry_id),
    PRIMARY KEY (release_sequence, old_entry_id, old_entry_usage_id),
    CHECK (
        (disposition = 'retired'
            AND new_entry_id IS NULL
            AND new_entry_usage_id IS NULL
            AND migration_release_sequence IS NULL)
        OR
        (disposition = 'redirected'
            AND new_entry_id IS NOT NULL
            AND new_entry_usage_id IS NOT NULL
            AND (
                (new_entry_id = old_entry_id
                    AND migration_release_sequence IS NULL)
                OR
                (new_entry_id <> old_entry_id
                    AND migration_release_sequence IS NOT NULL)
            ))
    )
) WITHOUT ROWID;

CREATE TABLE explanation_disposition (
    release_sequence INTEGER NOT NULL CHECK (release_sequence > 0),
    entry_id TEXT NOT NULL,
    entry_usage_id TEXT NOT NULL,
    old_explanation_id TEXT NOT NULL,
    disposition TEXT NOT NULL CHECK (disposition IN ('replaced', 'revoked')),
    replacement_explanation_id TEXT,
    locale TEXT NOT NULL,
    reason_code TEXT NOT NULL,
    FOREIGN KEY (replacement_explanation_id, entry_id, entry_usage_id, locale)
        REFERENCES released_lesson_variant(
            explanation_id, entry_id, entry_usage_id, locale
        ),
    PRIMARY KEY (release_sequence, old_explanation_id),
    CHECK (
        (disposition = 'replaced' AND replacement_explanation_id IS NOT NULL)
        OR
        (disposition = 'revoked' AND replacement_explanation_id IS NULL)
    )
) WITHOUT ROWID;

CREATE INDEX entry_usage_entry_order_idx
    ON entry_usage(entry_id, display_order);

CREATE INDEX lesson_entry_locale_idx
    ON released_lesson_variant(entry_id, locale, entry_usage_id);
