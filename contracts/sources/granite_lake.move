module granite_lake::photo_attestation {
    use sui::event;
    use sui::object::{Self, UID};
    use sui::table::{Self, Table};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const E_DOMAIN_EXISTS: u64 = 1;
    const E_DOMAIN_NOT_FOUND: u64 = 2;
    const E_NOT_ADMIN: u64 = 3;
    const E_USER_EXISTS: u64 = 4;
    const E_NOT_USER: u64 = 5;
    const E_USER_DISABLED: u64 = 6;
    const E_USER_NOT_FOUND: u64 = 7;

    public struct OwnerCap has key {
        id: UID,
    }

    public struct Registry has key {
        id: UID,
        domains: Table<vector<u8>, DomainRecord>,
    }

    public struct DomainRecord has store {
        admin_wallet: address,
        users: Table<address, bool>,
    }

    public struct UserCap has key {
        id: UID,
        domain: vector<u8>,
        user_wallet: address,
    }

    public struct DomainAdded has copy, drop {
        domain: vector<u8>,
        admin_wallet: address,
    }

    public struct UserAdded has copy, drop {
        domain: vector<u8>,
        admin_wallet: address,
        user_wallet: address,
    }

    public struct UserEnabled has copy, drop {
        domain: vector<u8>,
        admin_wallet: address,
        user_wallet: address,
    }

    public struct UserDisabled has copy, drop {
        domain: vector<u8>,
        admin_wallet: address,
        user_wallet: address,
    }

    public struct PhotoAttested has copy, drop {
        photo_hash: vector<u8>,
        gps: vector<u8>,
        altitude: vector<u8>,
        project_id: vector<u8>,
        user_wallet: address,
    }

    fun init(ctx: &mut TxContext) {
        let owner_cap = OwnerCap {
            id: object::new(ctx),
        };

        let registry = Registry {
            id: object::new(ctx),
            domains: table::new<vector<u8>, DomainRecord>(ctx),
        };

        transfer::transfer(owner_cap, tx_context::sender(ctx));
        transfer::share_object(registry);
    }

    public entry fun add_domain(
        _: &OwnerCap,
        registry: &mut Registry,
        domain: vector<u8>,
        admin_wallet: address,
        ctx: &mut TxContext,
    ) {
        assert!(!table::contains(&registry.domains, domain), E_DOMAIN_EXISTS);

        let domain_record = DomainRecord {
            admin_wallet,
            users: table::new<address, bool>(ctx),
        };

        table::add(&mut registry.domains, domain, domain_record);

        event::emit(DomainAdded {
            domain,
            admin_wallet,
        });
    }

    public entry fun add_user(
        registry: &mut Registry,
        domain: vector<u8>,
        user_wallet: address,
        ctx: &mut TxContext,
    ) {
        assert!(table::contains(&registry.domains, copy domain), E_DOMAIN_NOT_FOUND);

        let domain_record = table::borrow_mut(&mut registry.domains, copy domain);
        let admin_wallet = domain_record.admin_wallet;

        assert!(tx_context::sender(ctx) == admin_wallet, E_NOT_ADMIN);
        assert!(!table::contains(&domain_record.users, user_wallet), E_USER_EXISTS);

        table::add(&mut domain_record.users, user_wallet, true);

        let user_cap = UserCap {
            id: object::new(ctx),
            domain: copy domain,
            user_wallet,
        };

        transfer::transfer(user_cap, user_wallet);

        event::emit(UserAdded {
            domain,
            admin_wallet,
            user_wallet,
        });
    }

    public entry fun enable_user(
        registry: &mut Registry,
        domain: vector<u8>,
        user_wallet: address,
        ctx: &mut TxContext,
    ) {
        let admin_wallet = borrow_domain_admin(registry, copy domain);
        assert!(tx_context::sender(ctx) == admin_wallet, E_NOT_ADMIN);

        let domain_record = table::borrow_mut(&mut registry.domains, copy domain);
        assert!(table::contains(&domain_record.users, user_wallet), E_USER_NOT_FOUND);

        let enabled = table::borrow_mut(&mut domain_record.users, user_wallet);
        *enabled = true;

        event::emit(UserEnabled {
            domain,
            admin_wallet,
            user_wallet,
        });
    }

    public entry fun disable_user(
        registry: &mut Registry,
        domain: vector<u8>,
        user_wallet: address,
        ctx: &mut TxContext,
    ) {
        let admin_wallet = borrow_domain_admin(registry, copy domain);
        assert!(tx_context::sender(ctx) == admin_wallet, E_NOT_ADMIN);

        let domain_record = table::borrow_mut(&mut registry.domains, copy domain);
        assert!(table::contains(&domain_record.users, user_wallet), E_USER_NOT_FOUND);

        let enabled = table::borrow_mut(&mut domain_record.users, user_wallet);
        *enabled = false;

        event::emit(UserDisabled {
            domain,
            admin_wallet,
            user_wallet,
        });
    }

    public entry fun attest_photo(
        user_cap: &UserCap,
        registry: &Registry,
        hash: vector<u8>,
        gps: vector<u8>,
        altitude: vector<u8>,
        project_id: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);

        assert!(sender == user_cap.user_wallet, E_NOT_USER);
        assert_user_enabled(registry, user_cap, sender);

        event::emit(PhotoAttested {
            photo_hash: hash,
            gps,
            altitude,
            project_id,
            user_wallet: sender,
        });
    }

    fun borrow_domain_admin(
        registry: &Registry,
        domain: vector<u8>,
    ): address {
        assert!(table::contains(&registry.domains, copy domain), E_DOMAIN_NOT_FOUND);
        table::borrow(&registry.domains, domain).admin_wallet
    }

    fun assert_user_enabled(
        registry: &Registry,
        user_cap: &UserCap,
        sender: address,
    ) {
        assert!(table::contains(&registry.domains, copy user_cap.domain), E_DOMAIN_NOT_FOUND);

        let domain_record = table::borrow(&registry.domains, copy user_cap.domain);
        assert!(table::contains(&domain_record.users, sender), E_USER_NOT_FOUND);
        assert!(*table::borrow(&domain_record.users, sender), E_USER_DISABLED);
    }

    #[test_only]
    public fun transfer_user_cap_for_testing(user_cap: UserCap, to: address) {
        transfer::transfer(user_cap, to);
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}
