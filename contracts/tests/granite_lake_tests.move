#[test_only]
module granite_lake::granite_lake_tests;

use granite_lake::photo_attestation as pa;
use std::unit_test::assert_eq;
use sui::event;
use sui::test_scenario as ts;

const OWNER: address = @0x1;
const ADMIN: address = @0x2;
const USER: address = @0x3;
const OTHER: address = @0x4;

const E_DOMAIN_EXISTS: u64 = 1;
const E_NOT_ADMIN: u64 = 3;
const E_USER_EXISTS: u64 = 4;
const E_NOT_USER: u64 = 5;
const E_USER_DISABLED: u64 = 6;

fun setup_domain(scenario: &mut ts::Scenario, domain: vector<u8>) {
    scenario.next_tx(OWNER);
    {
        let owner_cap: pa::OwnerCap = scenario.take_from_sender();
        let mut registry: pa::Registry = scenario.take_shared();
        pa::add_domain(&owner_cap, &mut registry, domain, ADMIN, scenario.ctx());
        ts::return_shared(registry);
        scenario.return_to_sender(owner_cap);
    };
}

fun setup_domain_and_user(scenario: &mut ts::Scenario, domain: vector<u8>, user_wallet: address) {
    setup_domain(scenario, copy domain);

    scenario.next_tx(ADMIN);
    {
        let mut registry: pa::Registry = scenario.take_shared();
        pa::add_user(&mut registry, domain, user_wallet, scenario.ctx());
        ts::return_shared(registry);
    };
}

#[test]
fun test_add_domain_emits_domain_added_event() {
    let mut scenario = ts::begin(OWNER);
    let domain = b"example.com";
    pa::init_for_testing(scenario.ctx());

    scenario.next_tx(OWNER);
    {
        let owner_cap: pa::OwnerCap = scenario.take_from_sender();
        let mut registry: pa::Registry = scenario.take_shared();

        pa::add_domain(&owner_cap, &mut registry, domain, ADMIN, scenario.ctx());

        assert_eq!(event::num_events(), 1);
        assert_eq!(event::events_by_type<pa::DomainAdded>().length(), 1);

        ts::return_shared(registry);
        scenario.return_to_sender(owner_cap);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = E_DOMAIN_EXISTS, location = granite_lake::photo_attestation)]
fun test_add_domain_duplicate_domain_failure() {
    let mut scenario = ts::begin(OWNER);
    let domain = b"duplicate.com";
    pa::init_for_testing(scenario.ctx());

    scenario.next_tx(OWNER);
    {
        let owner_cap: pa::OwnerCap = scenario.take_from_sender();
        let mut registry: pa::Registry = scenario.take_shared();

        pa::add_domain(&owner_cap, &mut registry, copy domain, ADMIN, scenario.ctx());
        pa::add_domain(&owner_cap, &mut registry, domain, ADMIN, scenario.ctx());

        ts::return_shared(registry);
        scenario.return_to_sender(owner_cap);
    };

    scenario.end();
}

#[test]
fun test_add_user_emits_user_added_event() {
    let mut scenario = ts::begin(OWNER);
    let domain = b"users.com";
    pa::init_for_testing(scenario.ctx());

    setup_domain(&mut scenario, domain);

    scenario.next_tx(ADMIN);
    {
        let mut registry: pa::Registry = scenario.take_shared();
        pa::add_user(&mut registry, domain, USER, scenario.ctx());

        assert_eq!(event::num_events(), 1);
        assert_eq!(event::events_by_type<pa::UserAdded>().length(), 1);

        ts::return_shared(registry);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = E_NOT_ADMIN, location = granite_lake::photo_attestation)]
fun test_add_user_admin_only_failure() {
    let mut scenario = ts::begin(OWNER);
    let domain = b"admin-only.com";
    pa::init_for_testing(scenario.ctx());

    setup_domain(&mut scenario, copy domain);

    scenario.next_tx(OTHER);
    {
        let mut registry: pa::Registry = scenario.take_shared();
        pa::add_user(&mut registry, domain, USER, scenario.ctx());
        ts::return_shared(registry);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = E_USER_EXISTS, location = granite_lake::photo_attestation)]
fun test_add_user_duplicate_user_failure() {
    let mut scenario = ts::begin(OWNER);
    let domain = b"dupe-user.com";
    pa::init_for_testing(scenario.ctx());

    setup_domain(&mut scenario, copy domain);

    scenario.next_tx(ADMIN);
    {
        let mut registry: pa::Registry = scenario.take_shared();
        pa::add_user(&mut registry, copy domain, USER, scenario.ctx());
        pa::add_user(&mut registry, domain, USER, scenario.ctx());
        ts::return_shared(registry);
    };

    scenario.end();
}

#[test]
fun test_enable_user_and_disable_user_emit_events() {
    let mut scenario = ts::begin(OWNER);
    let domain = b"toggle-user.com";
    pa::init_for_testing(scenario.ctx());

    setup_domain_and_user(&mut scenario, copy domain, USER);

    scenario.next_tx(ADMIN);
    {
        let mut registry: pa::Registry = scenario.take_shared();
        pa::disable_user(&mut registry, copy domain, USER, scenario.ctx());

        assert_eq!(event::num_events(), 1);
        assert_eq!(event::events_by_type<pa::UserDisabled>().length(), 1);

        ts::return_shared(registry);
    };

    scenario.next_tx(ADMIN);
    {
        let mut registry: pa::Registry = scenario.take_shared();
        pa::enable_user(&mut registry, domain, USER, scenario.ctx());

        assert_eq!(event::num_events(), 1);
        assert_eq!(event::events_by_type<pa::UserEnabled>().length(), 1);

        ts::return_shared(registry);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = E_USER_DISABLED, location = granite_lake::photo_attestation)]
fun test_disabled_users_cannot_attest_photos() {
    let mut scenario = ts::begin(OWNER);
    let domain = b"disabled-attest.com";
    pa::init_for_testing(scenario.ctx());

    setup_domain_and_user(&mut scenario, copy domain, USER);

    scenario.next_tx(ADMIN);
    {
        let mut registry: pa::Registry = scenario.take_shared();
        pa::disable_user(&mut registry, domain, USER, scenario.ctx());
        ts::return_shared(registry);
    };

    scenario.next_tx(USER);
    {
        let user_cap: pa::UserCap = scenario.take_from_sender();
        let registry: pa::Registry = scenario.take_shared();

        pa::attest_photo(
            &user_cap,
            &registry,
            b"hash-1",
            b"6.9271,79.8612",
            b"12.4",
            b"project-disabled",
            scenario.ctx(),
        );

        ts::return_shared(registry);
        scenario.return_to_sender(user_cap);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = E_USER_DISABLED, location = granite_lake::photo_attestation)]
fun test_disabled_users_cannot_attest_files() {
    let mut scenario = ts::begin(OWNER);
    let domain = b"disabled-file-attest.com";
    pa::init_for_testing(scenario.ctx());

    setup_domain_and_user(&mut scenario, copy domain, USER);

    scenario.next_tx(ADMIN);
    {
        let mut registry: pa::Registry = scenario.take_shared();
        pa::disable_user(&mut registry, domain, USER, scenario.ctx());
        ts::return_shared(registry);
    };

    scenario.next_tx(USER);
    {
        let user_cap: pa::UserCap = scenario.take_from_sender();
        let registry: pa::Registry = scenario.take_shared();

        pa::attest_file(
            &user_cap,
            &registry,
            b"file-hash-1",
            b"file-1",
            b"project-disabled-file",
            scenario.ctx(),
        );

        ts::return_shared(registry);
        scenario.return_to_sender(user_cap);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = E_NOT_USER, location = granite_lake::photo_attestation)]
fun test_only_user_cap_owner_can_call_attest_photo() {
    let mut scenario = ts::begin(OWNER);
    let domain = b"owner-check.com";
    pa::init_for_testing(scenario.ctx());

    setup_domain_and_user(&mut scenario, copy domain, USER);

    scenario.next_tx(USER);
    {
        let user_cap: pa::UserCap = scenario.take_from_sender();
        pa::transfer_user_cap_for_testing(user_cap, OTHER);
    };

    scenario.next_tx(OTHER);
    {
        let user_cap: pa::UserCap = scenario.take_from_sender();
        let registry: pa::Registry = scenario.take_shared();

        pa::attest_photo(
            &user_cap,
            &registry,
            b"hash-2",
            b"6.9271,79.8612",
            b"23.9",
            b"project-owner-check",
            scenario.ctx(),
        );

        ts::return_shared(registry);
        scenario.return_to_sender(user_cap);
    };

    scenario.end();
}

#[test]
fun test_attest_photo_emits_photo_attested_event() {
    let mut scenario = ts::begin(OWNER);
    let domain = b"attest-event.com";
    pa::init_for_testing(scenario.ctx());

    setup_domain_and_user(&mut scenario, domain, USER);

    scenario.next_tx(USER);
    {
        let user_cap: pa::UserCap = scenario.take_from_sender();
        let registry: pa::Registry = scenario.take_shared();

        pa::attest_photo(
            &user_cap,
            &registry,
            b"hash-3",
            b"6.9271,79.8612",
            b"11.1",
            b"project-success",
            scenario.ctx(),
        );

        assert_eq!(event::num_events(), 1);
        assert_eq!(event::events_by_type<pa::PhotoAttested>().length(), 1);

        ts::return_shared(registry);
        scenario.return_to_sender(user_cap);
    };

    scenario.end();
}

#[test]
fun test_attest_file_emits_file_attested_event() {
    let mut scenario = ts::begin(OWNER);
    let domain = b"file-attest-event.com";
    pa::init_for_testing(scenario.ctx());

    setup_domain_and_user(&mut scenario, domain, USER);

    scenario.next_tx(USER);
    {
        let user_cap: pa::UserCap = scenario.take_from_sender();
        let registry: pa::Registry = scenario.take_shared();

        pa::attest_file(
            &user_cap,
            &registry,
            b"file-hash-2",
            b"file-2",
            b"project-file-success",
            scenario.ctx(),
        );

        assert_eq!(event::num_events(), 1);
        assert_eq!(event::events_by_type<pa::FileAttested>().length(), 1);

        ts::return_shared(registry);
        scenario.return_to_sender(user_cap);
    };

    scenario.end();
}
