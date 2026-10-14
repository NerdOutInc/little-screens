declare namespace Cloudflare {
  interface Env {
    DB?: D1Database;
    BUCKET?: R2Bucket;
    SITE_TOKEN?: string;
    SITE_ORIGIN?: string;
  }
}
