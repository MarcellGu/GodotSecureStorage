extends Node

const SECURE_STORAGE_SCRIPT: Script = preload("res://addon/secure_storage.gd")
const VALUE_ONE: String = "blackbox-value-one"
const VALUE_TWO: String = "blackbox-value-two"
const VALUE_ISOLATED: String = "blackbox-value-isolated"
const PROBE_VALUE: String = "blackbox-probe"
const PHASE_FILE: String = "user://secure-storage-e2e-phase"
const PRIMARY_DOMAIN: String = "com.marcellgu.testsecurestorage.primary"
const ISOLATED_DOMAIN: String = "com.marcellgu.testsecurestorage.isolated"
const PROBE_DOMAIN: String = "com.marcellgu.testsecurestorage.probe"


func _ready() -> void:
	var is_debug: bool = OS.has_feature("debug")
	var is_release: bool = OS.has_feature("release")
	var variant: String = "DEBUG" if is_debug else "RELEASE" if is_release else "UNKNOWN"
	if is_debug == is_release:
		print("TEST_SECURE_STORAGE result=FAIL")
		get_tree().quit(1)
		return

	var phase: String = OS.get_environment("SECURE_STORAGE_TEST_PHASE")
	var is_apple: bool = OS.has_feature("macos") or OS.has_feature("ios")
	var run_both: bool = phase.is_empty() and is_apple
	var uses_phase_file: bool = phase.is_empty() and not is_apple
	if not phase.is_empty() and phase != "WRITE" and phase != "READ":
		print("TEST_SECURE_STORAGE result=FAIL")
		get_tree().quit(1)
		return
	var read_phase: bool = phase == "READ" or (
			uses_phase_file and FileAccess.file_exists(PHASE_FILE)
	)
	var storage: Variant = SECURE_STORAGE_SCRIPT.new()

	if not read_phase or run_both:
		var probe_clear: Variant = storage.clear_domain(PROBE_DOMAIN)
		_print_operation("clear_domain", probe_clear)
		if probe_clear is SECURE_STORAGE_SCRIPT.StorageError:
			var probe_error: RefCounted = probe_clear
			print(
					"TEST_SECURE_STORAGE variant=%s result=ERROR error_type=%d message=%s"
					% [
						variant,
						int(probe_error.get("type")),
						String(probe_error.get("message")),
					]
			)
			get_tree().quit(1)
			return
		if not _expect_success(
				"clear_domain", probe_clear, PROBE_DOMAIN, "", "", false
		):
			_fail_test()
			return
		if not _expect_success(
				"set_value",
				storage.set_value(PROBE_DOMAIN, "probe", PROBE_VALUE),
				PROBE_DOMAIN,
				"probe",
				PROBE_VALUE
		):
			_fail_test()
			return
		if not _expect_success(
				"get_value",
				storage.get_value(PROBE_DOMAIN, "probe"),
				PROBE_DOMAIN,
				"probe",
				PROBE_VALUE
		):
			_fail_test()
			return
		if not _expect_success(
				"remove_value",
				storage.remove_value(PROBE_DOMAIN, "probe"),
				PROBE_DOMAIN,
				"probe",
				""
		):
			_fail_test()
			return
		if not _expect_error(
				"get_value",
				storage.get_value(PROBE_DOMAIN, "probe"),
				SECURE_STORAGE_SCRIPT.StorageError.ErrorType.NOT_FOUND
		):
			_fail_test()
			return
		if not _expect_success(
				"clear_domain",
				storage.clear_domain(PRIMARY_DOMAIN),
				PRIMARY_DOMAIN,
				"",
				""
		):
			_fail_test()
			return
		if not _expect_success(
				"clear_domain",
				storage.clear_domain(ISOLATED_DOMAIN),
				ISOLATED_DOMAIN,
				"",
				""
		):
			_fail_test()
			return
		if not _expect_success(
				"set_value",
				storage.set_value(PRIMARY_DOMAIN, "primary", VALUE_ONE),
				PRIMARY_DOMAIN,
				"primary",
				VALUE_ONE
		):
			_fail_test()
			return
		if not _expect_success(
				"set_value",
				storage.set_value(PRIMARY_DOMAIN, "empty", ""),
				PRIMARY_DOMAIN,
				"empty",
				""
		):
			_fail_test()
			return
		if not _expect_success(
				"set_value",
				storage.set_value(ISOLATED_DOMAIN, "primary", VALUE_ISOLATED),
				ISOLATED_DOMAIN,
				"primary",
				VALUE_ISOLATED
		):
			_fail_test()
			return
		if not _expect_error(
				"set_value",
				storage.set_value("", "key", "value"),
				SECURE_STORAGE_SCRIPT.StorageError.ErrorType.INVALID_ARGUMENT
		):
			_fail_test()
			return

		if not run_both:
			if uses_phase_file:
				var phase_file: FileAccess = FileAccess.open(PHASE_FILE, FileAccess.WRITE)
				if phase_file == null:
					print("TEST_SECURE_STORAGE result=FAIL")
					get_tree().quit(1)
					return
				phase_file.store_string("READ")
				var phase_error: int = phase_file.get_error()
				phase_file.close()
				if phase_error != OK:
					print("TEST_SECURE_STORAGE result=FAIL")
					get_tree().quit(1)
					return
			print("TEST_SECURE_STORAGE phase=WRITE variant=%s result=PASS" % variant)
			get_tree().quit(0)
			return

	if uses_phase_file:
		var phase_file: FileAccess = FileAccess.open(PHASE_FILE, FileAccess.READ)
		if phase_file == null or phase_file.get_as_text() != "READ":
			if phase_file != null:
				phase_file.close()
			print("TEST_SECURE_STORAGE result=FAIL")
			get_tree().quit(1)
			return
		phase_file.close()

	if not _expect_success(
			"get_value",
			storage.get_value(PRIMARY_DOMAIN, "primary"),
			PRIMARY_DOMAIN,
			"primary",
			VALUE_ONE
	):
		_fail_test()
		return
	if not _expect_success(
			"get_value",
			storage.get_value(PRIMARY_DOMAIN, "empty"),
			PRIMARY_DOMAIN,
			"empty",
			""
	):
		_fail_test()
		return
	if not _expect_success(
			"get_value",
			storage.get_value(ISOLATED_DOMAIN, "primary"),
			ISOLATED_DOMAIN,
			"primary",
			VALUE_ISOLATED
	):
		_fail_test()
		return
	if not _expect_success(
			"set_value",
			storage.set_value(PRIMARY_DOMAIN, "primary", VALUE_TWO),
			PRIMARY_DOMAIN,
			"primary",
			VALUE_TWO
	):
		_fail_test()
		return
	if not _expect_success(
			"get_value",
			storage.get_value(PRIMARY_DOMAIN, "primary"),
			PRIMARY_DOMAIN,
			"primary",
			VALUE_TWO
	):
		_fail_test()
		return
	if not _expect_success(
			"get_value",
			storage.get_value(ISOLATED_DOMAIN, "primary"),
			ISOLATED_DOMAIN,
			"primary",
			VALUE_ISOLATED
	):
		_fail_test()
		return
	if not _expect_success(
			"remove_value",
			storage.remove_value(PRIMARY_DOMAIN, "primary"),
			PRIMARY_DOMAIN,
			"primary",
			""
	):
		_fail_test()
		return
	if not _expect_error(
			"get_value",
			storage.get_value(PRIMARY_DOMAIN, "primary"),
			SECURE_STORAGE_SCRIPT.StorageError.ErrorType.NOT_FOUND
	):
		_fail_test()
		return
	if not _expect_success(
			"remove_value",
			storage.remove_value(PRIMARY_DOMAIN, "primary"),
			PRIMARY_DOMAIN,
			"primary",
			""
	):
		_fail_test()
		return
	if not _expect_success(
			"set_value",
			storage.set_value(PRIMARY_DOMAIN, "clear-second", VALUE_ONE),
			PRIMARY_DOMAIN,
			"clear-second",
			VALUE_ONE
	):
		_fail_test()
		return
	if not _expect_success(
			"clear_domain",
			storage.clear_domain(PRIMARY_DOMAIN),
			PRIMARY_DOMAIN,
			"",
			""
	):
		_fail_test()
		return
	if not _expect_error(
			"get_value",
			storage.get_value(PRIMARY_DOMAIN, "empty"),
			SECURE_STORAGE_SCRIPT.StorageError.ErrorType.NOT_FOUND
	):
		_fail_test()
		return
	if not _expect_error(
			"get_value",
			storage.get_value(PRIMARY_DOMAIN, "clear-second"),
			SECURE_STORAGE_SCRIPT.StorageError.ErrorType.NOT_FOUND
	):
		_fail_test()
		return
	if not _expect_success(
			"get_value",
			storage.get_value(ISOLATED_DOMAIN, "primary"),
			ISOLATED_DOMAIN,
			"primary",
			VALUE_ISOLATED
	):
		_fail_test()
		return
	if not _expect_success(
			"clear_domain",
			storage.clear_domain(ISOLATED_DOMAIN),
			ISOLATED_DOMAIN,
			"",
			""
	):
		_fail_test()
		return
	if not _expect_error(
			"get_value",
			storage.get_value(ISOLATED_DOMAIN, "primary"),
			SECURE_STORAGE_SCRIPT.StorageError.ErrorType.NOT_FOUND
	):
		_fail_test()
		return
	if not _expect_success(
			"clear_domain",
			storage.clear_domain(PRIMARY_DOMAIN),
			PRIMARY_DOMAIN,
			"",
			""
	):
		_fail_test()
		return
	if not _expect_success(
			"clear_domain",
			storage.clear_domain(ISOLATED_DOMAIN),
			ISOLATED_DOMAIN,
			"",
			""
	):
		_fail_test()
		return
	if not _expect_success(
			"clear_domain",
			storage.clear_domain(PROBE_DOMAIN),
			PROBE_DOMAIN,
			"",
			""
	):
		_fail_test()
		return

	if uses_phase_file and DirAccess.remove_absolute(
			ProjectSettings.globalize_path(PHASE_FILE)
	) != OK:
		print("TEST_SECURE_STORAGE result=FAIL")
		get_tree().quit(1)
		return
	print("TEST_SECURE_STORAGE variant=%s result=PASS" % variant)
	get_tree().quit(0)


func _expect_success(
		operation: String,
		raw_result: Variant,
		expected_domain: String,
		expected_key: String,
		expected_value: String,
		print_operation: bool = true
) -> bool:
	if print_operation:
		_print_operation(operation, raw_result)
	if not raw_result is SECURE_STORAGE_SCRIPT.StorageSuccess:
		print(
				"ASSERTION_FAILED operation=%s expected=StorageSuccess"
				% operation
		)
		return false
	var result: RefCounted = raw_result
	var actual_domain: String = String(result.get("domain"))
	var actual_key: String = String(result.get("key"))
	var actual_value: String = String(result.get("value"))
	if (
			actual_domain != expected_domain
			or actual_key != expected_key
			or actual_value != expected_value
	):
		print(
				"ASSERTION_FAILED operation=%s expected_domain=%s expected_key=%s expected_value=%s"
				% [
					operation,
					expected_domain,
					expected_key,
					expected_value,
				]
		)
		return false
	return true


func _expect_error(
		operation: String,
		raw_result: Variant,
		expected_type: int
) -> bool:
	_print_operation(operation, raw_result)
	if not raw_result is SECURE_STORAGE_SCRIPT.StorageError:
		print(
				"ASSERTION_FAILED operation=%s expected=StorageError code=%d"
				% [operation, expected_type]
		)
		return false
	var error: RefCounted = raw_result
	var actual_type: int = int(error.get("type"))
	var actual_message: String = String(error.get("message"))
	if actual_type != expected_type or actual_message.is_empty():
		print(
				"ASSERTION_FAILED operation=%s expected_code=%d expected_nonempty_message=true"
				% [operation, expected_type]
		)
		return false
	return true


func _fail_test() -> void:
	print("TEST_SECURE_STORAGE result=FAIL")
	get_tree().quit(1)


func _print_operation(operation: String, raw_result: Variant) -> void:
	if raw_result is SECURE_STORAGE_SCRIPT.StorageSuccess:
		var result: RefCounted = raw_result
		print(
				"operation=%s domain=%s key=%s value=%s"
				% [
					operation,
					String(result.get("domain")),
					String(result.get("key")),
					String(result.get("value")),
				]
		)
	elif raw_result is SECURE_STORAGE_SCRIPT.StorageError:
		var error: RefCounted = raw_result
		print(
				"operation=%s code=%d message=%s"
				% [operation, int(error.get("type")), String(error.get("message"))]
		)
	else:
		print("operation=%s code=4 message=unexpected result type %d" % [operation, typeof(raw_result)])
