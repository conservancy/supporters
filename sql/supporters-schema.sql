-- Conservancy Supporter Database, Version 0.2

DROP TABLE IF EXISTS "donor";

CREATE TABLE "donor" (
    "id" integer NOT NULL PRIMARY KEY,
    "ledger_entity_id" varchar(300) NOT NULL UNIQUE,
    "display_name" varchar(300),
    "public_ack"   bool,
    "is_supporter" bool NOT NULL
);

DROP TABLE IF EXISTS "request";

CREATE TABLE "request" (
    "id" integer NOT NULL PRIMARY KEY,
    "donor_id" integer NOT NULL,
    "request_type_id" integer NOT NULL,
    "request_configuration_id" integer,
    "date_requested" date NOT NULL,
    "notes" TEXT
    );

CREATE UNIQUE INDEX request__one_request_for_each_type_per_donor
   ON request(donor_id, request_type_id);

DROP TABLE IF EXISTS "request_configuration";

CREATE TABLE "request_configuration" (
    "id" integer NOT NULL PRIMARY KEY,
    "request_type_id" integer NOT NULL,
    "description"   varchar(100) NOT NULL
    );

CREATE UNIQUE INDEX request_configuration__single_description
   ON request_configuration(request_type_id, description);

DROP TABLE IF EXISTS "fulfillment";

CREATE TABLE "fulfillment" (
    "id" integer NOT NULL PRIMARY KEY,
    "request_id" integer NOT NULL,
    "date" TEXT NOT NULL,
    "who" varchar(300) NOT NULL,
    "how" TEXT
);

CREATE UNIQUE INDEX fulfillment__one_fulfillment_per_request ON fulfillment(request_id);

DROP TABLE IF EXISTS "request_hold";

CREATE TABLE "request_hold" (
    "id" integer NOT NULL PRIMARY KEY,
    "request_id" integer NOT NULL,
    "hold_date" TEXT NOT NULL,
    "release_date" TEXT,
    "who" varchar(300) NOT NULL,
    "why" TEXT
);

CREATE UNIQUE INDEX request_hold__one_hold_per_request ON request_hold(request_id);

DROP TABLE IF EXISTS "request_type";

CREATE TABLE "request_type" (
    "id" integer NOT NULL PRIMARY KEY,
    "type"   varchar(100) NOT NULL
    );

DROP TABLE IF EXISTS "delivery_error";

CREATE TABLE "delivery_error" (
    "id" integer NOT NULL PRIMARY KEY,
    "error" varchar(300) NOT NULL UNIQUE
    );

DROP TABLE IF EXISTS "email_address";

CREATE TABLE "email_address" (
    "id" integer NOT NULL PRIMARY KEY,
    "email_address" varchar(300) NOT NULL UNIQUE,
    "type_id" integer,
    "date_encountered" date NOT NULL
    );

DROP TABLE IF EXISTS "email_error_log";

CREATE TABLE "email_error_log" (
    "email_address_id" integer NOT NULL,
    "delivery_error_code_id" integer NOT NULL,
    "date_encountered" date NOT NULL,
    "comments" TEXT
    );

DROP TABLE IF EXISTS "donor_email_address_mapping";

CREATE TABLE "donor_email_address_mapping" (
    "donor_id" integer NOT NULL,
    "email_address_id" integer NOT NULL,
    "preferred" bool,
    PRIMARY KEY(donor_id, email_address_id)
    );

DROP TABLE IF EXISTS "address_type";

CREATE TABLE "address_type" (
    "id" integer NOT NULL PRIMARY KEY,
    "name" varchar(50) NOT NULL UNIQUE
    );

DROP TABLE IF EXISTS "postal_address";

CREATE TABLE "postal_address" (
    "id" integer NOT NULL PRIMARY KEY,
    "formatted_address" varchar(5000),
    "type_id" INTEGER NOT NULL,
    "date_encountered" date NOT NULL
    );

DROP TABLE IF EXISTS "donor_postal_address_mapping";

CREATE TABLE "donor_postal_address_mapping" (
    "donor_id" integer NOT NULL,
    "postal_address_id" integer NOT NULL,
    "preferred" bool,
    PRIMARY KEY(donor_id, postal_address_id)
    );

CREATE UNIQUE INDEX donor_postal_address_mapping_single_prefferred_per_donor
   ON donor_postal_address_mapping(donor_id, preferred);
