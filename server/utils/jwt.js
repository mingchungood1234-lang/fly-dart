const jwt = require('jsonwebtoken');

const JWT_SECRET = process.env.JWT_SECRET || 'fallback_secret_change_me';
const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN || '7d';

function generateToken(userId) {
  return jwt.sign({ id: userId }, JWT_SECRET, { expiresIn: JWT_EXPIRES_IN });
}

function verifyToken(token) {
  return jwt.verify(token, JWT_SECRET);
}

/**
 * Verify token allowing expired tokens (for refresh flow).
 * Returns decoded token if valid (even if expired).
 * Returns null if token is invalid or too old (more than 30 days).
 */
function verifyTokenForRefresh(token) {
  try {
    // Allow expired tokens but verify the signature
    return jwt.verify(token, JWT_SECRET, { ignoreExpiration: true });
  } catch (error) {
    // Token is invalid (wrong signature, malformed, etc.)
    return null;
  }
}

module.exports = { generateToken, verifyToken, verifyTokenForRefresh };
