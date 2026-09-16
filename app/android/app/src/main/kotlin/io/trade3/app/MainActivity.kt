package io.trade3.app

import android.os.Build
import android.os.Bundle
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Log
import android.view.WindowManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.InvalidAlgorithmParameterException
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.spec.MGF1ParameterSpec
import java.util.UUID
import javax.crypto.BadPaddingException
import javax.crypto.Cipher
import javax.crypto.IllegalBlockSizeException
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource

class MainActivity : FlutterFragmentActivity() {
	private val channelName = "granite_lake/biometric_gate"
	private val keyStoreProvider = "AndroidKeyStore"
	private val logTag = "GraniteLakeCapture"

	// Offline-queue at-rest encryption: a single, long-lived RSA keypair (not
	// per-capture) used to wrap/unwrap each row's random AES data key. Unlike
	// the AES gate above, an asymmetric key lets the public half wrap a data
	// key with zero biometric involvement (capture must never block on a
	// prompt, even fully offline with no recent auth), while the private
	// half stays Keystore-gated so unwrapping - and therefore resubmitting -
	// a queued row always needs a fresh biometric check.
	//
	// _v2: bumped because Keystore keys are immutable - the v1 key was
	// generated with per-operation auth (no validity window), which turned
	// out to be incompatible with batch-decrypting more than one item per
	// prompt (see captureWrapKeyValidityDurationSeconds below). Any
	// already-queued row wrapped under v1 cannot be recovered under v2 and
	// needs to be recaptured.
	private val captureWrapKeyAlias = "granite_lake_capture_wrap_key_v2"

	// How long after one successful biometric auth the private key stays
	// usable without prompting again - keep this in sync with Dart's
	// AppConstants.queueUnlockDurationMinutes (currently 5 minutes: 300s).
	// This is what actually makes "one prompt unlocks the whole batch"
	// possible: a Keystore2 operation closes the moment doFinal() is
	// called, so reusing one authenticated Cipher object for a second
	// item's doFinal() fails with KEY_USER_NOT_AUTHENTICATED (confirmed
	// on-device) - Cipher.doFinal() only resets the JCA-level object, not
	// the underlying Keystore operation. A validity-duration key sidesteps
	// this entirely: every item gets its own fresh Cipher.init()+doFinal(),
	// each authorized by "was there a recent successful biometric auth"
	// rather than by being tied to one specific CryptoObject.
	private val captureWrapKeyValidityDurationSeconds = 300

	// Explicit OAEP parameters, used identically for both wrap (public key,
	// software path) and unwrap (private key, Keystore-enforced path).
	// Relying on the transformation string alone
	// ("RSA/ECB/OAEPWithSHA-256AndMGF1Padding") to imply the MGF1 digest is
	// a well-documented Android Keystore trap: `setDigests(SHA256)` at key
	// generation only authorizes SHA-256 as the *main* OAEP digest - the
	// MGF1 digest is a separate authorization that defaults to (and, below
	// API 33's setMgf1Digests(), can only ever be) SHA-1. Requesting
	// SHA-256 for both, as the transformation string implies, makes the
	// public-key wrap succeed (software path, unenforced) while every
	// unwrap fails with `KeyStoreException ... INCOMPATIBLE_MGF_DIGEST` -
	// confirmed against a real KeyMint error, not just a hypothesis.
	// SHA-256 main digest + SHA-1 MGF1 is the documented, universally
	// supported combination for this exact failure.
	private val captureWrapOaepParams = OAEPParameterSpec(
		"SHA-256",
		"MGF1",
		MGF1ParameterSpec.SHA1,
		PSource.PSpecified.DEFAULT,
	)

	private var pendingResult: MethodChannel.Result? = null
	private var pendingCreateAliasForCleanup: String? = null

	override fun onCreate(savedInstanceState: Bundle?) {
		// Every screen in this app can show captured evidence photos or their
		// metadata. Block screenshots, screen recording, and the recent-apps
		// thumbnail for the whole activity rather than picking screens to
		// exempt.
		window.setFlags(
			WindowManager.LayoutParams.FLAG_SECURE,
			WindowManager.LayoutParams.FLAG_SECURE,
		)
		super.onCreate(savedInstanceState)
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
			.setMethodCallHandler { call, result ->
				when (call.method) {
					"createBiometricGate" -> createBiometricGate(call, result)
					"unlockBiometricGate" -> unlockBiometricGate(call, result)
					"deleteBiometricGate" -> deleteBiometricGate(call, result)
					"ensureCaptureWrapKey" -> ensureCaptureWrapKey(call, result)
					"wrapCaptureDataKey" -> wrapCaptureDataKey(call, result)
					"unwrapCaptureDataKeys" -> unwrapCaptureDataKeys(call, result)
					else -> result.notImplemented()
				}
			}
	}

	private fun createBiometricGate(call: MethodCall, result: MethodChannel.Result) {
		if (!ensureNoPendingOperation(result) || !ensureBiometricSupport(result)) {
			return
		}

		val payload = call.argument<String>("payload")
		if (payload.isNullOrEmpty()) {
			result.error("invalid_arguments", "Missing biometric gate payload.", null)
			return
		}

		val alias = "granite_gate_${UUID.randomUUID()}"
		pendingResult = result
		try {
			generateSecretKey(alias)
			val cipher = initEncryptCipher(alias)
			pendingCreateAliasForCleanup = alias
			authenticate(
				title = "Bind biometrics",
				subtitle = "Create a secure biometric gate for Trade3.",
				cipher = cipher,
				onSuccess = { authenticatedCipher ->
					val ciphertext = authenticatedCipher.doFinal(payload.toByteArray(Charsets.UTF_8))
					pendingCreateAliasForCleanup = null
					finishSuccess(
						mapOf(
							"alias" to alias,
							"ciphertextBase64" to android.util.Base64.encodeToString(
								ciphertext,
								android.util.Base64.NO_WRAP,
							),
							"ivBase64" to android.util.Base64.encodeToString(
								authenticatedCipher.iv,
								android.util.Base64.NO_WRAP,
							),
						),
					)
				},
			)
		} catch (error: KeyPermanentlyInvalidatedException) {
			pendingCreateAliasForCleanup = null
			deleteKeyIfPresent(alias)
			finishError("biometric_changed", "Biometrics changed on this device. Re-bind required.")
		} catch (error: Exception) {
			pendingCreateAliasForCleanup = null
			deleteKeyIfPresent(alias)
			finishError("binding_failed", error.message ?: "Biometric gate creation failed.")
		}
	}

	private fun unlockBiometricGate(call: MethodCall, result: MethodChannel.Result) {
		if (!ensureNoPendingOperation(result) || !ensureBiometricSupport(result)) {
			return
		}

		val alias = call.argument<String>("alias")
		val ciphertextBase64 = call.argument<String>("ciphertextBase64")
		val ivBase64 = call.argument<String>("ivBase64")
		val title = call.argument<String>("title")?.takeIf { it.isNotBlank() } ?: "Unlock secure session"
		val subtitle = call.argument<String>("subtitle")?.takeIf { it.isNotBlank() }
			?: "Verify biometrics to unlock Trade3."

		if (alias.isNullOrBlank() || ciphertextBase64.isNullOrBlank() || ivBase64.isNullOrBlank()) {
			result.error("invalid_arguments", "Missing biometric gate payload.", null)
			return
		}

		pendingResult = result
		try {
			val iv = android.util.Base64.decode(ivBase64, android.util.Base64.DEFAULT)
			val ciphertext = android.util.Base64.decode(ciphertextBase64, android.util.Base64.DEFAULT)
			val cipher = initDecryptCipher(alias, iv)
			authenticate(
				title = title,
				subtitle = subtitle,
				cipher = cipher,
				onSuccess = { authenticatedCipher ->
					val plaintext = authenticatedCipher.doFinal(ciphertext)
					finishSuccess(String(plaintext, Charsets.UTF_8))
				},
			)
		} catch (error: KeyPermanentlyInvalidatedException) {
			finishError("biometric_changed", "Biometrics changed on this device. Re-bind required.")
		} catch (error: UnrecoverableBiometricGateException) {
			finishError(error.code, error.message)
		} catch (error: Exception) {
			finishError("unlock_failed", error.message ?: "Biometric gate unlock failed.")
		}
	}

	private fun deleteBiometricGate(call: MethodCall, result: MethodChannel.Result) {
		val alias = call.argument<String>("alias")
		if (alias.isNullOrBlank()) {
			result.success(null)
			return
		}

		deleteKeyIfPresent(alias)
		result.success(null)
	}

	// Offline-queue at-rest encryption (capture_encryption_service.dart).
	// idempotent - generates the wrap keypair only if this device doesn't
	// already have one. No auth: creating an asymmetric keypair touches
	// neither half's key material in a way that needs gating.
	private fun ensureCaptureWrapKey(call: MethodCall, result: MethodChannel.Result) {
		try {
			val keyStore = KeyStore.getInstance(keyStoreProvider).apply { load(null) }
			if (!keyStore.containsAlias(captureWrapKeyAlias)) {
				generateCaptureWrapKeyPair()
				Log.d(logTag, "ensureCaptureWrapKey: generated new keypair")
			} else {
				Log.d(logTag, "ensureCaptureWrapKey: keypair already present")
			}
			result.success(null)
		} catch (error: Exception) {
			Log.e(logTag, "ensureCaptureWrapKey failed: ${error.message}")
			result.error("wrap_key_failed", error.message ?: "Could not prepare capture wrap key.", null)
		}
	}

	// Wraps one row's random AES-256 data key with the RSA public key - a
	// public-key operation, so Android Keystore never gates it behind
	// biometrics regardless of the private key's setUserAuthenticationRequired
	// flag. Safe to call at capture time with no session and no connectivity.
	private fun wrapCaptureDataKey(call: MethodCall, result: MethodChannel.Result) {
		val dataKeyBase64 = call.argument<String>("dataKeyBase64")
		val captureId = call.argument<String>("captureId") ?: "unknown"
		if (dataKeyBase64.isNullOrEmpty()) {
			result.error("invalid_arguments", "Missing data key to wrap.", null)
			return
		}

		try {
			val keyStore = KeyStore.getInstance(keyStoreProvider).apply { load(null) }
			val certificate = keyStore.getCertificate(captureWrapKeyAlias)
				?: throw IllegalStateException("Capture wrap key not found.")
			val cipher = Cipher.getInstance("RSA/ECB/OAEPPadding")
			cipher.init(Cipher.ENCRYPT_MODE, certificate.publicKey, captureWrapOaepParams)
			val rawKeyBytes = android.util.Base64.decode(dataKeyBase64, android.util.Base64.NO_WRAP)
			Log.d(
				logTag,
				"wrapCaptureDataKey[$captureId]: attempting wrap, rawKeyBytes=${rawKeyBytes.size}",
			)
			val wrapped = cipher.doFinal(rawKeyBytes)
			Log.d(logTag, "wrapCaptureDataKey[$captureId]: wrap succeeded, wrappedBytes=${wrapped.size}")
			result.success(android.util.Base64.encodeToString(wrapped, android.util.Base64.NO_WRAP))
		} catch (error: Exception) {
			Log.e(
				logTag,
				"wrapCaptureDataKey[$captureId] failed: ${error::class.java.simpleName}: ${error.message}",
				error,
			)
			result.error("wrap_failed", error.message ?: "Could not wrap capture data key.", null)
		}
	}

	// Batch-unwraps every currently-queued row's wrapped data key behind a
	// single biometric prompt: Cipher.doFinal() resets an initialized cipher
	// back to a ready state rather than invalidating it, so the same
	// authenticated CryptoObject from one BiometricPrompt success can decrypt
	// every wrapped key in the batch without a prompt per row. A per-item
	// failure (a tampered wrapped_data_key column) is reported as a null at
	// that index rather than failing the whole batch, so one bad row doesn't
	// block the rest of the queue from submitting.
	private fun unwrapCaptureDataKeys(call: MethodCall, result: MethodChannel.Result) {
		if (!ensureNoPendingOperation(result) || !ensureBiometricSupport(result)) {
			return
		}

		val wrappedKeys = call.argument<List<String>>("wrappedKeysBase64")
		val captureIds = call.argument<List<String>>("captureIds") ?: emptyList()
		if (wrappedKeys.isNullOrEmpty()) {
			result.error("invalid_arguments", "No wrapped keys supplied.", null)
			return
		}

		pendingResult = result
		try {
			val keyStore = KeyStore.getInstance(keyStoreProvider).apply { load(null) }
			val privateKey = keyStore.getKey(captureWrapKeyAlias, null) as? java.security.PrivateKey
				?: throw UnrecoverableBiometricGateException("gate_missing", "Capture wrap key not found.")
			// This Cipher only exists to give the BiometricPrompt below a
			// CryptoObject to bind to and trigger the actual prompt UI - its
			// doFinal() is never called. Every batch item below gets its own
			// freshly-init'd Cipher instead, because a Keystore2 operation
			// closes the moment doFinal() is called once; a validity-duration
			// key (captureWrapKeyValidityDurationSeconds) is what lets each
			// of those fresh Ciphers succeed without its own prompt, as long
			// as they're all within the window this one authentication opens.
			val promptCipher = Cipher.getInstance("RSA/ECB/OAEPPadding")
			promptCipher.init(Cipher.DECRYPT_MODE, privateKey, captureWrapOaepParams)

			Log.d(logTag, "unwrapCaptureDataKeys: prompting for batch of ${wrappedKeys.size}")
			authenticate(
				title = "Unlock queued captures",
				subtitle = "Verify biometrics to decrypt and submit queued captures.",
				cipher = promptCipher,
				onSuccess = {
					val unwrapped = wrappedKeys.mapIndexed { index, wrappedKeyBase64 ->
						val captureId = captureIds.getOrNull(index) ?: "unknown"
						try {
							val wrappedBytes = android.util.Base64.decode(
								wrappedKeyBase64,
								android.util.Base64.NO_WRAP,
							)
							Log.d(
								logTag,
								"unwrapCaptureDataKeys[$captureId]: attempting unwrap, wrappedBytes=${wrappedBytes.size}",
							)
							val itemCipher = Cipher.getInstance("RSA/ECB/OAEPPadding")
							itemCipher.init(Cipher.DECRYPT_MODE, privateKey, captureWrapOaepParams)
							val plainBytes = itemCipher.doFinal(wrappedBytes)
							Log.d(
								logTag,
								"unwrapCaptureDataKeys[$captureId]: unwrap succeeded, plainBytes=${plainBytes.size}",
							)
							android.util.Base64.encodeToString(plainBytes, android.util.Base64.NO_WRAP)
						} catch (error: Exception) {
							// Logged at class-name granularity (BadPaddingException vs.
							// IllegalBlockSizeException vs. anything else) since that's
							// what distinguishes "genuinely tampered ciphertext" from "we
							// built the Cipher with mismatched OAEP parameters" while
							// debugging this path.
							Log.e(
								logTag,
								"unwrapCaptureDataKeys[$captureId] failed: ${error::class.java.simpleName}: ${error.message}",
								error,
							)
							null
						}
					}
					finishSuccess(unwrapped)
				},
			)
		} catch (error: KeyPermanentlyInvalidatedException) {
			finishError("biometric_changed", "Biometrics changed on this device. Re-bind required.")
		} catch (error: UnrecoverableBiometricGateException) {
			finishError(error.code, error.message)
		} catch (error: Exception) {
			Log.e(
				logTag,
				"unwrapCaptureDataKeys setup failed: ${error::class.java.simpleName}: ${error.message}",
				error,
			)
			finishError("unlock_failed", error.message ?: "Could not unlock queued captures.")
		}
	}

	private fun generateCaptureWrapKeyPair() {
		val keyPairGenerator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, keyStoreProvider)
		val builder = KeyGenParameterSpec.Builder(
			captureWrapKeyAlias,
			KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
		)
			.setKeySize(2048)
			.setDigests(KeyProperties.DIGEST_SHA256)
			.setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
			// Only gates the private (decrypt/unwrap) half - Android Keystore
			// never requires auth for a public-key operation, which is what
			// keeps wrapCaptureDataKey prompt-free.
			.setUserAuthenticationRequired(true)
			.setInvalidatedByBiometricEnrollment(true)
			// Legacy (pre-API-30) validity-duration API - see
			// captureWrapKeyValidityDurationSeconds's doc for why a
			// time-bound window, not per-operation auth, is required here.
			.setUserAuthenticationValidityDurationSeconds(captureWrapKeyValidityDurationSeconds)

		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
			// The API-30+ replacement for the legacy call above - a timeout
			// of 0 here means "per operation" and would silently override
			// the legacy setting on this OS version, which is exactly the
			// bug that caused every second batch item to fail with
			// KEY_USER_NOT_AUTHENTICATED. Must match
			// captureWrapKeyValidityDurationSeconds, not 0.
			builder.setUserAuthenticationParameters(
				captureWrapKeyValidityDurationSeconds,
				KeyProperties.AUTH_BIOMETRIC_STRONG,
			)
		}

		keyPairGenerator.initialize(builder.build())
		keyPairGenerator.generateKeyPair()
	}

	private fun authenticate(
		title: String,
		subtitle: String,
		cipher: Cipher,
		onSuccess: (Cipher) -> Unit,
	) {
		val executor = ContextCompat.getMainExecutor(this)
		val prompt = BiometricPrompt(
			this,
			executor,
			object : BiometricPrompt.AuthenticationCallback() {
				override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
					finishError(
						when (errorCode) {
							BiometricPrompt.ERROR_CANCELED,
							BiometricPrompt.ERROR_NEGATIVE_BUTTON,
							BiometricPrompt.ERROR_USER_CANCELED -> "auth_cancelled"
							else -> "auth_failed"
						},
						errString.toString(),
					)
				}

				override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
					val authenticatedCipher = result.cryptoObject?.cipher
					if (authenticatedCipher == null) {
						finishError("auth_failed", "Biometric prompt did not return a crypto object.")
						return
					}

					try {
						onSuccess(authenticatedCipher)
					} catch (error: KeyPermanentlyInvalidatedException) {
						finishError(
							"biometric_changed",
							"Biometrics changed on this device. Re-bind required.",
						)
					} catch (error: BadPaddingException) {
						finishError("gate_missing", "Stored biometric gate could not be unlocked.")
					} catch (error: IllegalBlockSizeException) {
						finishError("gate_missing", "Stored biometric gate could not be unlocked.")
					} catch (error: Exception) {
						finishError("auth_failed", error.message ?: "Biometric authentication failed.")
					}
				}
			},
		)

		val promptInfo = BiometricPrompt.PromptInfo.Builder()
			.setTitle(title)
			.setSubtitle(subtitle)
			.setNegativeButtonText("Cancel")
			.apply {
				if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
					setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
				}
			}
			.build()

		prompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(cipher))
	}

	private fun ensureNoPendingOperation(result: MethodChannel.Result): Boolean {
		if (pendingResult == null) {
			return true
		}

		result.error("operation_pending", "Another biometric operation is already in progress.", null)
		return false
	}

	private fun ensureBiometricSupport(result: MethodChannel.Result): Boolean {
		val biometricManager = BiometricManager.from(this)
		val canAuthenticate = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
			biometricManager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
		} else {
			@Suppress("DEPRECATION")
			biometricManager.canAuthenticate()
		}

		return when (canAuthenticate) {
			BiometricManager.BIOMETRIC_SUCCESS -> true
			BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> {
				result.error("biometric_unavailable", "No biometrics are enrolled on this device.", null)
				false
			}
			BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE,
			BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> {
				result.error("biometric_unavailable", "Biometric authentication is unavailable on this device.", null)
				false
			}
			else -> {
				result.error("biometric_unavailable", "Biometric authentication is unavailable.", null)
				false
			}
		}
	}

	private fun generateSecretKey(alias: String) {
		val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, keyStoreProvider)
		val builder = KeyGenParameterSpec.Builder(
			alias,
			KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
		)
			.setBlockModes(KeyProperties.BLOCK_MODE_GCM)
			.setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
			.setUserAuthenticationRequired(true)
			.setInvalidatedByBiometricEnrollment(true)
			.setRandomizedEncryptionRequired(true)
			.setUserAuthenticationValidityDurationSeconds(-1)

		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
			builder.setUserAuthenticationParameters(
				0,
				KeyProperties.AUTH_BIOMETRIC_STRONG,
			)
		}

		keyGenerator.init(builder.build())
		keyGenerator.generateKey()
	}

	private fun initEncryptCipher(alias: String): Cipher {
		val cipher = Cipher.getInstance("AES/GCM/NoPadding")
		cipher.init(Cipher.ENCRYPT_MODE, loadSecretKey(alias))
		return cipher
	}

	private fun initDecryptCipher(alias: String, iv: ByteArray): Cipher {
		val cipher = Cipher.getInstance("AES/GCM/NoPadding")
		try {
			cipher.init(
				Cipher.DECRYPT_MODE,
				loadSecretKey(alias),
				GCMParameterSpec(128, iv),
			)
		} catch (error: InvalidAlgorithmParameterException) {
			throw UnrecoverableBiometricGateException(
				"gate_missing",
				"Stored biometric gate could not be unlocked.",
			)
		}
		return cipher
	}

	private fun loadSecretKey(alias: String): SecretKey {
		val keyStore = KeyStore.getInstance(keyStoreProvider).apply { load(null) }
		val secretKey = keyStore.getKey(alias, null) as? SecretKey
		if (secretKey == null) {
			throw UnrecoverableBiometricGateException(
				"gate_missing",
				"Stored biometric gate could not be found.",
			)
		}
		return secretKey
	}

	private fun deleteKeyIfPresent(alias: String) {
		val keyStore = KeyStore.getInstance(keyStoreProvider).apply { load(null) }
		if (keyStore.containsAlias(alias)) {
			keyStore.deleteEntry(alias)
		}
	}

	private fun finishSuccess(payload: Any?) {
		val result = pendingResult ?: return
		pendingResult = null
		pendingCreateAliasForCleanup = null
		result.success(payload)
	}

	private fun finishError(code: String, message: String) {
		val cleanupAlias = pendingCreateAliasForCleanup
		pendingCreateAliasForCleanup = null
		if (cleanupAlias != null) {
			deleteKeyIfPresent(cleanupAlias)
		}

		val result = pendingResult ?: return
		pendingResult = null
		result.error(code, message, null)
	}
}

private class UnrecoverableBiometricGateException(
	val code: String,
	override val message: String,
) : IllegalStateException(message)