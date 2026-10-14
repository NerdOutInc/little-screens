import { integer, sqliteTable, text } from "drizzle-orm/sqlite-core";

// The registry and idempotency receipts commit together in one CAS update.
export const registry = sqliteTable("registry", {
  id: text("id").primaryKey(),
  version: integer("version").notNull().default(0),
  data: text("data").notNull(),
});
export const checkins = sqliteTable("checkins", {
  id: text("id").primaryKey(),
  seen: text("seen"),
  imageSent: text("image_sent"),
  publicationId: text("publication_id"),
});
