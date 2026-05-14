import { createClient } from "@supabase/supabase-js";

const SUPABASE_URL = "https://ebhaztndepodowsxfbmw.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_UxEPSa9z0XzkFEFAstGtoA_sC9aufto";
const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

async function check() {
  const { data, error } = await supabase.from('users').select('*').limit(1);
  if (error) {
    console.error("Error querying users table:", error.message);
  } else {
    console.log("Users table exists! Row count:", data.length);
  }
}

check();
