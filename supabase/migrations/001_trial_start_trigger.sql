-- Supabase trigger: set trial_start in user_metadata on signup
-- Run this in Supabase Dashboard → SQL Editor
--
-- This ensures every new user gets a trial_start timestamp in their
-- raw_user_meta_data, which is included in JWTs. The Cloudflare Worker
-- reads this to calculate trial expiry (instead of the unreliable iat claim).

-- 1. Create the trigger function
CREATE OR REPLACE FUNCTION public.set_trial_start()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Only set trial_start if not already present (e.g., admin-created users)
  IF NOT (NEW.raw_user_meta_data ? 'trial_start') THEN
    NEW.raw_user_meta_data = jsonb_set(
      COALESCE(NEW.raw_user_meta_data, '{}'::jsonb),
      '{trial_start}',
      to_jsonb(extract(epoch FROM NEW.created_at)::bigint)
    );
  END IF;
  RETURN NEW;
END;
$$;

-- 2. Create the trigger (BEFORE INSERT so we can modify the row)
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  BEFORE INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.set_trial_start();

-- 3. Backfill existing users who don't have trial_start yet
UPDATE auth.users
SET raw_user_meta_data = jsonb_set(
  COALESCE(raw_user_meta_data, '{}'::jsonb),
  '{trial_start}',
  to_jsonb(extract(epoch FROM created_at)::bigint)
)
WHERE NOT (raw_user_meta_data ? 'trial_start');
