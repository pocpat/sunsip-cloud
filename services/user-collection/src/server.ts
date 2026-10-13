// user-collection — SunSip Microservice 2 (auth, preferences, saved
// combinations, rate limits, system settings) on Express + ONE DynamoDB table.
//
// Ported 1:1 from the Netlify functions in api/ (same routes, same status
// codes, same error messages) so the frontend only changes its base URL.
// In production this runs on ECS Fargate behind its own public ALB.
//
// Routes (paths keep the /api/ prefix the frontend already uses):
//   POST /api/auth-signup      POST /api/auth-signin     POST /api/auth-signout
//   GET  /api/auth-me          POST /api/auth-forgot     POST /api/auth-reset
//   GET|POST /api/combinations         DELETE|PATCH /api/combination
//   GET|PUT  /api/preferences          POST /api/request-limit
//   GET  /api/system-settings          GET  /healthz

import express from 'express';
import cors from 'cors';
import { randomUUID, createHash } from 'crypto';
import nodemailer, { createTransport } from 'nodemailer';
import {
  ddb,
  TABLE,
  userPk,
  getItem,
  queryByPK,
  queryByIndex,
  updateItem,
  deleteItem,
  putUser,
  putIfAbsent,
} from './lib/ddb.js';
import {
  signToken,
  hashPassword,
  comparePassword,
  getAuthUserFromHeaders,
  setAuthCookie,
  clearAuthCookie,
} from './lib/auth.js';

const PORT = Number(process.env.PORT || 4002);
const app = express();
const router = express.Router();
app.use(cors({ origin: true, credentials: true }));
app.use(express.json());

type Authed = { id: string; email: string; isAdmin: boolean } | null;

function requireAuth(req: express.Request): Authed {
  return getAuthUserFromHeaders(req.headers as Record<string, string>);
}

const DAILY_LIMIT = 10;

function sha256(value: string): string {
  return createHash('sha256').update(value).digest('hex');
}

function getNextMidnightUTC(now = new Date()): Date {
  const next = new Date(now);
  next.setUTCHours(24, 0, 0, 0);
  return next;
}

function getUTCDateKey(date: Date): string {
  return date.toISOString().slice(0, 10);
}

// ----------------------------------------------------------------- auth-signup

router.post('/auth-signup', async (req, res) => {
  try {
    const { email, password } = req.body || {};
    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password are required.' });
    }
    const normalizedEmail = String(email).toLowerCase().trim();
    if (password.length < 6) {
      return res.status(400).json({ error: 'Password must be at least 6 characters.' });
    }

    // Duplicate check via the email GSI.
    const existing = await queryByIndex('GSI2', 'GSI2PK', `EMAIL#${normalizedEmail}`);
    if (existing.length > 0) {
      return res.status(409).json({ error: 'A user with this email already exists.' });
    }

    const passwordHash = await hashPassword(password);
    const now = new Date();
    const userId = randomUUID();

    // User profile + default preferences — two items, same partition.
    await putUser({
      PK: userPk(userId),
      SK: 'PROFILE',
      GSI2PK: `EMAIL#${normalizedEmail}`,
      GSI2SK: 'USER',
      id: userId,
      email: normalizedEmail,
      passwordHash,
      isAdmin: false,
      createdAt: now.toISOString(),
    });
    await putIfAbsent({
      PK: userPk(userId),
      SK: 'PREFS',
      userId,
      preferredSpirits: [],
      dietaryRestrictions: [],
      favoriteWeatherMoods: {},
      dailyRequestCount: 0,
      lastRequestDate: null as string | null,
      createdAt: now.toISOString(),
      updatedAt: now.toISOString(),
    });

    const token = signToken({ id: userId, email: normalizedEmail, isAdmin: false });
    res.setHeader('Set-Cookie', setAuthCookie(token));
    return res.status(201).json({ user: { id: userId, email: normalizedEmail, isAdmin: false } });
  } catch (error) {
    console.error('Signup error:', error);
    return res.status(500).json({ error: 'Failed to create user.' });
  }
});

// ----------------------------------------------------------------- auth-signin

router.post('/auth-signin', async (req, res) => {
  try {
    const { email, password } = req.body || {};
    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password are required.' });
    }
    const normalizedEmail = String(email).toLowerCase().trim();

    const matches = await queryByIndex('GSI2', 'GSI2PK', `EMAIL#${normalizedEmail}`);
    const user = matches[0] ?? null;
    if (!user) {
      return res.status(401).json({ error: 'Invalid email or password.' });
    }

    const valid = await comparePassword(password, user.passwordHash);
    if (!valid) {
      return res.status(401).json({ error: 'Invalid email or password.' });
    }

    const token = signToken({ id: user.id, email: user.email, isAdmin: !!user.isAdmin });
    res.setHeader('Set-Cookie', setAuthCookie(token));
    return res.status(200).json({
      user: { id: user.id, email: user.email, isAdmin: !!user.isAdmin },
    });
  } catch (error) {
    console.error('Signin error:', error);
    return res.status(500).json({ error: 'Failed to sign in.' });
  }
});

// ---------------------------------------------------------------- auth-signout

router.post('/auth-signout', async (_req, res) => {
  try {
    res.setHeader('Set-Cookie', clearAuthCookie());
    return res.status(200).json({ message: 'Signed out successfully.' });
  } catch (error) {
    console.error('Signout error:', error);
    return res.status(500).json({ error: 'Failed to sign out.' });
  }
});

// ------------------------------------------------------------------- auth-me

router.get('/auth-me', async (req, res) => {
  try {
    const authUser = requireAuth(req);
    if (!authUser) {
      return res.status(401).json({ error: 'Not authenticated.' });
    }
    const user = await getItem(userPk(authUser.id), 'PROFILE');
    if (!user) {
      return res.status(401).json({ error: 'User not found.' });
    }
    return res.status(200).json({
      user: { id: user.id, email: user.email, isAdmin: !!user.isAdmin, createdAt: user.createdAt },
    });
  } catch (error) {
    console.error('Auth-me error:', error);
    return res.status(500).json({ error: 'Failed to fetch user.' });
  }
});

// ---------------------------------------------------------------- auth-forgot

const TOKEN_TTL_MS = 60 * 60 * 1000; // 1 hour

async function sendResetEmail(smtpUser: string, smtpPass: string, toEmail: string, resetUrl: string) {
  const transporter = createTransport({
    host: 'smtp.gmail.com',
    port: 465,
    secure: true,
    auth: { user: smtpUser, pass: smtpPass },
  });
  await transporter.sendMail({
    from: `SunSip <${smtpUser}>`,
    to: toEmail,
    subject: 'Reset your SunSip password',
    html: `
      <div style="font-family:Arial,Helvetica,sans-serif;max-width:480px;margin:0 auto;padding:24px;">
        <h2 style="color:#0c4a6e;">Reset your password</h2>
        <p>We received a request to reset the password for your SunSip account.</p>
        <p style="margin:28px 0;">
          <a href="${resetUrl}"
             style="background:#0284c7;color:#ffffff;padding:12px 24px;border-radius:6px;text-decoration:none;font-weight:bold;">
            Choose a new password
          </a>
        </p>
        <p style="color:#64748b;font-size:13px;">
          This link works once and expires in 1 hour. If you didn't request this,
          you can safely ignore this email — your password stays unchanged.
        </p>
      </div>`,
  });
}

router.post('/auth-forgot', async (req, res) => {
  try {
    const { email } = req.body || {};
    if (!email) {
      return res.status(400).json({ error: 'Email is required.' });
    }
    const normalizedEmail = String(email).toLowerCase().trim();

    const matches = await queryByIndex('GSI2', 'GSI2PK', `EMAIL#${normalizedEmail}`);
    const user = matches[0] ?? null;

    // Never reveal whether the account exists.
    if (user) {
      const token = sha256(normalizedEmail + Date.now() + Math.random()); // raw token lives only in the link
      const now = new Date();

      await putUser({
        PK: `RESET#${sha256(token)}`,
        SK: 'TOKEN',
        userId: user.id,
        expiresAt: new Date(now.getTime() + TOKEN_TTL_MS).toISOString(),
        usedAt: null as string | null,
        createdAt: now.toISOString(),
      });

      const origin = (req.headers?.origin as string) || 'http://localhost:5173';
      const resetUrl = `${origin}/#reset-token=${token}`;

      const smtpUser = process.env.SMTP_USER;
      const smtpPass = process.env.SMTP_PASS;
      if (smtpUser && smtpPass) {
        await sendResetEmail(smtpUser, smtpPass, normalizedEmail, resetUrl);
        return res.status(200).json({ message: 'Check your inbox — we sent a reset link.' });
      }

      // Email not configured: return the link so the flow still works (demo).
      console.log('auth-forgot: SMTP not configured, returning resetUrl directly');
      return res.status(200).json({
        message: 'Email service is not set up yet — use this link to reset your password:',
        delivered: false,
        resetUrl,
      });
    }

    return res.status(200).json({ message: 'If that email exists, a reset link is on its way.' });
  } catch (error) {
    console.error('Forgot-password error:', error);
    return res.status(500).json({ error: 'Failed to start password reset.' });
  }
});

// ----------------------------------------------------------------- auth-reset

router.post('/auth-reset', async (req, res) => {
  try {
    const { token, password } = req.body || {};
    if (!token || !password) {
      return res.status(400).json({ error: 'Reset link and new password are required.' });
    }
    if (String(password).length < 6) {
      return res.status(400).json({ error: 'Password must be at least 6 characters.' });
    }

    const doc = await getItem(`RESET#${sha256(String(token))}`, 'TOKEN');
    if (!doc || doc.usedAt || new Date(doc.expiresAt).getTime() < Date.now()) {
      return res.status(400).json({
        error: 'This reset link is invalid, already used, or expired. Please request a new one.',
      });
    }

    const passwordHash = await hashPassword(String(password));
    const updated = await updateItem(userPk(doc.userId), 'PROFILE', { passwordHash });
    if (!updated) {
      return res.status(400).json({ error: 'Account not found. Please sign up instead.' });
    }

    // Burn the token: single use.
    await updateItem(`RESET#${sha256(String(token))}`, 'TOKEN', {
      usedAt: new Date().toISOString(),
    });

    // Sign the user in with the new password.
    const jwt = signToken({
      id: doc.userId,
      email: updated?.email ?? '',
      isAdmin: !!updated?.isAdmin,
    });
    res.setHeader('Set-Cookie', setAuthCookie(jwt));
    return res.status(200).json({
      user: { id: doc.userId, email: updated?.email ?? '', isAdmin: !!updated?.isAdmin },
    });
  } catch (error) {
    console.error('Reset-password error:', error);
    return res.status(500).json({ error: 'Failed to reset password.' });
  }
});

// --------------------------------------------------- combinations (list/save)

router.get('/combinations', async (req, res) => {
  try {
    const authUser = requireAuth(req);
    if (!authUser) {
      return res.status(401).json({ error: 'Not authenticated.' });
    }
    const items: Record<string, any>[] = await queryByPK(userPk(authUser.id), { skPrefix: 'FAV#' });
    items.sort((a: any, b: any) => String(b.createdAt).localeCompare(String(a.createdAt)));
    return res.status(200).json({ combinations: items });
  } catch (error) {
    console.error('Combinations error:', error);
    return res.status(500).json({ error: 'Failed to handle combinations request.' });
  }
});

router.post('/combinations', async (req, res) => {
  try {
    const authUser = requireAuth(req);
    if (!authUser) {
      return res.status(401).json({ error: 'Not authenticated.' });
    }
    const body = req.body || {};
    const now = new Date();
    const id = randomUUID();

    const item = {
      PK: userPk(authUser.id),
      SK: `FAV#${id}`,
      GSI1PK: `${userPk(authUser.id)}#FAV`,
      id,
      userId: authUser.id,
      cityName: body.cityName || null,
      countryName: body.countryName || null,
      cityImageUrl: body.cityImageUrl || null,
      weatherDetails: body.weatherDetails || null,
      cocktailName: body.cocktailName || null,
      cocktailImageUrl: body.cocktailImageUrl || null,
      cocktailIngredients: Array.isArray(body.cocktailIngredients) ? body.cocktailIngredients : [],
      cocktailRecipe: Array.isArray(body.cocktailRecipe) ? body.cocktailRecipe : [],
      rating: typeof body.rating === 'number' ? body.rating : null,
      notes: body.notes || '',
      timesAccessed: 0,
      lastAccessedAt: null as string | null,
      createdAt: now.toISOString(),
    };

    await putUser(item);
    return res.status(201).json({ combination: item });
  } catch (error) {
    console.error('Combinations error:', error);
    return res.status(500).json({ error: 'Failed to handle combinations request.' });
  }
});

// ------------------------------------------- combination (delete / update)

router.delete('/combination', async (req, res) => {
  try {
    const authUser = requireAuth(req);
    if (!authUser) {
      return res.status(401).json({ error: 'Not authenticated.' });
    }
    const id = String(req.query.id || '');
    if (!id) {
      return res.status(400).json({ error: 'Combination id is required.' });
    }
    const existing = await getItem(userPk(authUser.id), `FAV#${id}`);
    if (!existing) {
      return res.status(404).json({ error: 'Combination not found.' });
    }
    await deleteItem(userPk(authUser.id), `FAV#${id}`);
    return res.status(200).json({ message: 'Combination deleted.' });
  } catch (error) {
    console.error('Combination error:', error);
    return res.status(500).json({ error: 'Failed to handle combination request.' });
  }
});

router.patch('/combination', async (req, res) => {
  try {
    const authUser = requireAuth(req);
    if (!authUser) {
      return res.status(401).json({ error: 'Not authenticated.' });
    }
    const id = String(req.query.id || '');
    if (!id) {
      return res.status(400).json({ error: 'Combination id is required.' });
    }
    const body = req.body || {};

    if (body.trackAccess) {
      const existing = await getItem(userPk(authUser.id), `FAV#${id}`);
      if (!existing) {
        return res.status(404).json({ error: 'Combination not found.' });
      }
      const updated = await updateItem(userPk(authUser.id), `FAV#${id}`, {
        timesAccessed: (existing.timesAccessed ?? 0) + 1,
        lastAccessedAt: new Date().toISOString(),
      });
      return res.status(200).json({ combination: updated });
    }

    const update: Record<string, unknown> = { updatedAt: new Date().toISOString() };
    if (typeof body.rating === 'number') update.rating = body.rating;
    if (typeof body.notes === 'string') update.notes = body.notes;

    const existing = await getItem(userPk(authUser.id), `FAV#${id}`);
    if (!existing) {
      return res.status(404).json({ error: 'Combination not found.' });
    }
    const updated = await updateItem(userPk(authUser.id), `FAV#${id}`, update);
    return res.status(200).json({ combination: updated });
  } catch (error) {
    console.error('Combination error:', error);
    return res.status(500).json({ error: 'Failed to handle combination request.' });
  }
});

// ---------------------------------------------------------------- preferences

async function getOrCreatePrefs(userId: string) {
  const existing = await getItem(userPk(userId), 'PREFS');
  if (existing) return existing;
  const now = new Date().toISOString();
  const defaults = {
    PK: userPk(userId),
    SK: 'PREFS',
    userId,
    preferredSpirits: [] as string[],
    dietaryRestrictions: [] as string[],
    favoriteWeatherMoods: {} as Record<string, unknown>,
    dailyRequestCount: 0,
    lastRequestDate: null as string | null,
    createdAt: now,
    updatedAt: now,
  };
  await putIfAbsent(defaults);
  return defaults;
}

router.get('/preferences', async (req, res) => {
  try {
    const authUser = requireAuth(req);
    if (!authUser) {
      return res.status(401).json({ error: 'Not authenticated.' });
    }
    const prefs = await getOrCreatePrefs(authUser.id);
    return res.status(200).json({ preferences: prefs });
  } catch (error) {
    console.error('Preferences error:', error);
    return res.status(500).json({ error: 'Failed to handle preferences request.' });
  }
});

router.put('/preferences', async (req, res) => {
  try {
    const authUser = requireAuth(req);
    if (!authUser) {
      return res.status(401).json({ error: 'Not authenticated.' });
    }
    const body = req.body || {};
    await getOrCreatePrefs(authUser.id);
    const updated = await updateItem(userPk(authUser.id), 'PREFS', {
      preferredSpirits: Array.isArray(body.preferredSpirits) ? body.preferredSpirits : [],
      dietaryRestrictions: Array.isArray(body.dietaryRestrictions) ? body.dietaryRestrictions : [],
      favoriteWeatherMoods:
        body.favoriteWeatherMoods && typeof body.favoriteWeatherMoods === 'object'
          ? body.favoriteWeatherMoods
          : {},
      updatedAt: new Date().toISOString(),
    });
    return res.status(200).json({ preferences: updated });
  } catch (error) {
    console.error('Preferences error:', error);
    return res.status(500).json({ error: 'Failed to handle preferences request.' });
  }
});

// -------------------------------------------------------------- request-limit

router.post('/request-limit', async (req, res) => {
  try {
    // Check system settings for global_enabled flag.
    const settings = await getItem('SETTINGS', 'GLOBAL');
    const globalEnabled = settings ? settings.value !== false : true;

    const authUser = requireAuth(req);
    const body = req.body || {};
    const userId = body.userId || (authUser ? authUser.id : null);
    const clientId = body.clientId || null;

    // Admin users get unlimited requests.
    if (authUser && authUser.isAdmin) {
      return res.status(200).json({
        canProceed: true,
        count: 0,
        remaining: Infinity,
        resetDate: getNextMidnightUTC(),
        unlimited: true,
      });
    }

    if (!globalEnabled) {
      return res.status(200).json({
        canProceed: false,
        count: 0,
        remaining: 0,
        resetDate: getNextMidnightUTC(),
        reason: 'global_disabled',
      });
    }

    const now = new Date();
    const todayKey = getUTCDateKey(now);

    if (userId) {
      const prefs = await getOrCreatePrefs(String(userId));
      const lastDateKey = prefs.lastRequestDate ? getUTCDateKey(new Date(prefs.lastRequestDate)) : null;
      const shouldReset = !prefs.lastRequestDate || lastDateKey !== todayKey;
      const currentCount = shouldReset ? 0 : prefs.dailyRequestCount || 0;

      if (currentCount >= DAILY_LIMIT) {
        return res.status(200).json({
          canProceed: false,
          count: currentCount,
          remaining: 0,
          resetDate: getNextMidnightUTC(now),
        });
      }

      const newCount = currentCount + 1;
      await updateItem(userPk(String(userId)), 'PREFS', {
        dailyRequestCount: newCount,
        lastRequestDate: now.toISOString(),
        updatedAt: now.toISOString(),
      });
      return res.status(200).json({
        canProceed: true,
        count: newCount,
        remaining: DAILY_LIMIT - newCount,
        resetDate: getNextMidnightUTC(now),
      });
    }

    // Anonymous client tracking.
    if (!clientId) {
      return res.status(400).json({ error: 'Either userId or clientId is required.' });
    }

    const pk = `ANON#${clientId}`;
    const existing = await getItem(pk, 'RATE');
    const lastDateKey = existing?.lastRequestDate
      ? getUTCDateKey(new Date(existing.lastRequestDate))
      : null;
    const shouldReset = !existing || !existing.lastRequestDate || lastDateKey !== todayKey;
    const currentCount = shouldReset ? 0 : existing.dailyRequestCount || 0;

    if (currentCount >= DAILY_LIMIT) {
      return res.status(200).json({
        canProceed: false,
        count: currentCount,
        remaining: 0,
        resetDate: getNextMidnightUTC(now),
      });
    }

    const newCount = currentCount + 1;
    if (existing) {
      await updateItem(pk, 'RATE', {
        dailyRequestCount: newCount,
        lastRequestDate: now.toISOString(),
      });
    } else {
      await putUser({
        PK: pk,
        SK: 'RATE',
        dailyRequestCount: newCount,
        lastRequestDate: now.toISOString(),
      });
    }

    return res.status(200).json({
      canProceed: true,
      count: newCount,
      remaining: DAILY_LIMIT - newCount,
      resetDate: getNextMidnightUTC(now),
    });
  } catch (error) {
    console.error('Request-limit error:', error);
    return res.status(500).json({ error: 'Failed to check request limit.' });
  }
});

// ------------------------------------------------------------ system-settings

router.get('/system-settings', async (req, res) => {
  try {
    const settingsItem = await getItem('SETTINGS', 'GLOBAL');
    const authUser = requireAuth(req);
    return res.status(200).json({
      settings: {
        global_enabled: settingsItem ? settingsItem.value !== false : true,
        dailyRequestLimit: settingsItem?.dailyRequestLimit ?? 10,
        isAdmin: !!(authUser && authUser.isAdmin),
      },
    });
  } catch (error) {
    console.error('System-settings error:', error);
    return res.status(500).json({ error: 'Failed to fetch system settings.' });
  }
});

// -------------------------------------------------------------------- health

app.get('/healthz', async (_req, res) => {
  try {
    await getItem('SETTINGS', 'GLOBAL'); // cheap round-trip proof
    return res.status(200).json({ ok: true, table: TABLE });
  } catch (error) {
    return res.status(500).json({ ok: false, error: (error as Error).message });
  }
});

// Mount every /api/user/* route under the app; /healthz stays at the root
// for the ALB health check in Phase 2.
app.use('/api/user', router);

app.listen(PORT, () => {
  console.log(`user-collection service listening on http://localhost:${PORT}`);
});