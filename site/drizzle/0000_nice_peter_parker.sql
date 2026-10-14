CREATE TABLE `checkins` (
	`id` text PRIMARY KEY NOT NULL,
	`seen` text,
	`image_sent` text,
	`publication_id` text
);
--> statement-breakpoint
CREATE TABLE `registry` (
	`id` text PRIMARY KEY NOT NULL,
	`version` integer DEFAULT 0 NOT NULL,
	`data` text NOT NULL
);
