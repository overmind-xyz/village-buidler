/* 
    This community-built quest introduces an on-chain, incremental-adjacent game. Users can create 
    villages and upgrade buildings in their villages. Village ownership is represented by an village
    NFT. 

    Village NFT collection:
        Ownership of a village will be represented by an NFT from the village NFT collection that is 
        to be created by the module's resource account. The name of the village NFT collection is 
        "Village collection name". The collection has an unlimited supply of tokens and no royalty. 
        The collection's description is "Village collection description". The collection's URI is 
        "Village collection URI".
    
    Village NFT: 
        Each village is represented by an NFT. Each NFT's name will be the village id and the name. 
        For example, if the first village is named "My village", the NFT's name will be "Village #1:
        My village". Another example, if the 894th village is named "Earl's village of greatness", 
        NFT's name will be "Village #894: \"Earl's village of greatness\"". The NFT's description will 
        be "Village collection description". The NFT's URI will be "Village collection URI". The 
        NFT's royalty will be 0. 

        Every NFT will own a Village resource which holds all of the data about the village. Check 
        the village resource struct for more details about the village data. 

    Buildings: 
        Each building has a unique ID. The list of buildings and their IDs are defined in the
        BUILDING_ID_* constants. 
        
        Each building has a max level. The max level of each building is defined in the
        BUILDING_MAX_LEVELS vector constant. Buildings cannot be upgraded past their max level. 
        Every upgrade increases the building's level by 1. Each building has a building upgrade cost 
        in APT. The building upgrade cost is defined in the BUILDING_UPGRADE_COST vector constant. 
        All upgrade APT costs are paid to the module's resource account. Each building also has a 
        building upgrade duration which specifies how long an upgrade will take to complete. The 
        building upgrade duration is defined in the BUILDING_UPGRADE_DURATION vector constant. Only 
        one building can be upgrading at a time in a village. For example, if a player starts an 
        upgrade for the Town Hall (level 0), they cannot start an upgrade for any other building 
        until after 60 seconds (the upgrade timestamp must be less than or equal to the current 
        timestamp to upgrade something else). 

        Some buildings require other buildings to be upgraded to a certain level before they can be 
        upgraded. The list of required buildings and their required levels are defined in the
        BUILDING_REQUIREMENTS vector constant.

    Key Concepts: 
        - NFTs
        - Aptos Coin
        - Game building
*/
module overmind::village_builder {
    //==============================================================================================
    // Dependencies 
    //==============================================================================================

    use std::option;
    use std::signer;
    use std::string;
    use std::vector;
    use std::string::String;
    use aptos_framework::coin;
    use aptos_framework::object;
    use aptos_std::string_utils;
    use aptos_framework::timestamp;
    use aptos_token_objects::token;
    use aptos_token_objects::collection;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account::{Self, new_event_handle, SignerCapability};

    #[test_only]
    use aptos_framework::aptos_coin;

    //==============================================================================================
    // Constants - DO NOT MODIFY PROVIDED CONSTANTS
    //==============================================================================================

    // seed for the module's resource account
    const SEED: vector<u8> = b"village builder";

    // Building IDs - All of the buildings that are in a village
    const BUILDING_ID_TOWN_HALL: u8 = 1;
    const BUILDING_ID_HEADQUARTERS: u8 = 2;
    const BUILDING_ID_BARRACKS: u8 = 3;
    const BUILDING_ID_CLAY_PIT: u8 = 4;
    const BUILDING_ID_FOREST_CAMP: u8 = 5;
    const BUILDING_ID_STONE_MINE: u8 = 6;
    const BUILDING_ID_STOREHOUSE: u8 = 7;
    const BUILDING_ID_SMITHY: u8 = 8;
    const BUILDING_ID_FARM: u8 = 9;
    const BUILDING_ID_HIDDEN_STASH: u8 = 10;
    const BUILDING_ID_WALL: u8 = 11;
    const BUILDING_ID_MARKET: u8 = 12;

    // Maximum level of each building - Buildings cannot be upgraded past this level
    //
    // [building_id, max_building_level]
    const BUILDING_MAX_LEVELS: vector<vector<u8>> = vector[
        vector[1, 5],
        vector[2, 1],
        vector[3, 5],
        vector[4, 6],
        vector[5, 6],
        vector[6, 6],
        vector[7, 10],
        vector[8, 6],
        vector[9, 10],
        vector[10, 1],
        vector[11, 1],
        vector[12, 1]
    ];

    // Some buildings require other buildings to be upgraded to a certain level before they can be
    // upgraded. This is the list of required buildings and their required levels.
    //
    // [building_id, required_building_id, required_building_level]
    const BUILDING_REQUIREMENTS: vector<vector<u8>> = vector[
        vector[2, 1, 3],
        vector[3, 1, 2],
        vector[8, 3, 3],
        vector[11, 3, 1],
        vector[12, 1, 5]
    ];

    // Building level to upgrade duration (in seconds)
    // 
    // [building_level, upgrade_duration_seconds]
    const BUILDING_UPGRADE_DURATION: vector<vector<u64>> = vector [
        vector[1, 60],
        vector[2, 120],
        vector[3, 200],
        vector[4, 300],
        vector[5, 500],
        vector[6, 700],
        vector[7, 900],
        vector[8, 1000],
        vector[9, 1500],
        vector[10, 2000],
    ];

    // Upgrade costs of each building
    //
    // [building_id, ugrade_cost]
    const BUILDING_UPGRADE_COST: vector<vector<u64>> = vector [
        vector[1, 500],
        vector[2, 10000],
        vector[3, 500],
        vector[4, 600],
        vector[5, 600],
        vector[6, 600],
        vector[7, 100],
        vector[8, 600],
        vector[9, 100],
        vector[10, 10000],
        vector[11, 5000],
        vector[12, 10000]
    ];

    //==============================================================================================
    // Error codes - DO NOT MODIFY
    //==============================================================================================
    const ECodeForAllErrors: u64 = 452094752;

    //==============================================================================================
    // Module structs - DO NOT MODIFY
    //==============================================================================================

    /*
        Module resource to store module data. To be owned by the module's resource account.
    */
    struct State has key {
        // List of villages - id to village address
        //
        // village IDs start from 1
        villages: SimpleMap<u64, address>,
        // Incrementing counter for indexing villages
        //
        // village IDs start from 1
        village_id: u64,
        // Resource account's SingerCapability
        signer_capability: SignerCapability,
        // Village collection address
        collection_address: address,
        // Events
        create_village_events: EventHandle<CreateVillageEvent>,
        upgrade_building_events: EventHandle<UpgradeBuildingEvent>,
    }

    /*
        Village struct to store village data. To be owned by each village NFT.
    */
    struct Village has store, drop, copy, key {
        // Village name - provided by the village creator
        name: String,
        // Village description - provided by the village creator
        description: String,
        // Buildings: building ID to current building level
        // Note: a village starts with all buildings at level 0
        buildings: SimpleMap<u8, u8>,
        // Timestamp of when building upgrade will finish and new one can start
        // Note: a new building can be upgrade if the current timestamp is greater than or equal to 
        // this timestamp
        building_upgrade_unlock_timestamp_seconds: u64,
    }

    //==============================================================================================
    // Event structs - DO NOT MODIFY
    //==============================================================================================

    /* 
        Event to be emitted when a new village is built
    */
    struct CreateVillageEvent has store, drop {
        // Address of the player who built the village
        village_builder: address,
        // Address of the village NFT
        village_address: address,
        // Timestamp (in seconds) of when the village was built
        village_creation_timestamp_seconds: u64,
    }

    /* 
        Event to be emitted when a building is upgraded
    */
    struct UpgradeBuildingEvent has store, drop {
        // Address of the village NFT
        village_address: address,
        // Id of the building that was upgraded
        building_id: u8,
        // New level of the building
        new_building_level: u8,
        // Timestamp (in seconds) of when the building was upgraded
        building_upgrade_timestamp_seconds: u64,
    }

    //==============================================================================================
    // Functions
    //==============================================================================================

    /*
        Initializes the module by setting up the resource account (with the provided SEED constant), 
        registering the resource account with the AptosCoin, creating the village NFT collection, 
        and creating and moving the State resource to the resource account.
        @param admin - signer representing the admin
    */
    fun init_module(admin: &signer) {
        
    }

    /*
        Build a new village for a player. Creates the new village NFT and transfers it to the user.
        Updates the State resource with the new village.
        @param village_builder - signer representing the player's account
        @param name - name of the village
        @param description - description of the village
    */
    public entry fun build_village(
        village_builder: &signer,
        name: String,
        description: String,
    ) acquires State {

    }

    /*
        Upgrade a building in a village. Aborts if the village or building does not exist, if the 
        player does not own the village, the player has insufficient APT or if any of the building 
        requirements or upgrade rules are not met. 
        @param account - player's account
        @param village_id - id of the village
        @param building_id - id of the building to upgrade
    */
    public fun upgrade_building(
        account: &signer,
        village_id: u64,
        building_id: u8,
    ) acquires State, Village {
        
    }

    //==============================================================================================
    // Helper functions
    //==============================================================================================

    /* 
        Returns the max level of a specific building.
        @param building_id - id of the building
        @return - max level of the building
    */
    #[view]
    public fun get_building_max_level(
        building_id: u8,
    ): u8 {
        
    }

    /* 
        Returns the building requirements for a specific building. Return (0, 0) if there are no 
        requirements.
        @param building_id - id of the building
        @return - (required_building_id, required_building_level)
    */
    #[view]
    public fun get_building_requirements(
        building_id: u8,
    ): (u8, u8) {
        
    }

    /* 
        Returns the building upgrade duration in seconds for a specific building level.
        @param building_level - level of the building
        @return - building upgrade duration in seconds
    */
    #[view]
    public fun get_building_level_upgrade_duration(
        building_level: u8,
    ): u64 {
        
    }

    /* 
        Returns the building upgrade cost in APT for a specific building.
        @param building_id - id of the building
        @return - building upgrade cost in APT
    */
    #[view]
    public fun get_building_upgrade_cost(
        building_id: u8,
    ): u64 {
        
    }

    //==============================================================================================
    // Validation functions
    //==============================================================================================

    //==============================================================================================
    // Tests - DO NOT MODIFY
    //==============================================================================================

    #[test(admin = @overmind)]
    fun test_init_module_success(admin: &signer) acquires State {
        let admin_address = signer::address_of(admin);

        account::create_account_for_test(admin_address);

        init_module(admin);

        let expected_resource_account_address = 
            account::create_resource_address(&admin_address, b"village builder");

        assert!(coin::is_account_registered<AptosCoin>(expected_resource_account_address), 4);

        assert!(exists<State>(expected_resource_account_address), 0);

        let state = borrow_global<State>(expected_resource_account_address);
        let create_village_events_counter = event::counter(&state.create_village_events);
        let upgrade_building_events_counter = event::counter(&state.upgrade_building_events);

        assert!(create_village_events_counter == 0, 2);
        assert!(upgrade_building_events_counter == 0, 3);
        assert!(
            simple_map::length(&state.villages) == 0, 
            5
        );
        assert!(
            state.village_id == 1, 
            6
        );
        assert!(
            account::get_signer_capability_address(&state.signer_capability) == 
                expected_resource_account_address,
            7
        );

        let expected_village_collection_address = collection::create_collection_address(
            &expected_resource_account_address, 
            &string::utf8(b"Village collection name")
        );
        let village_collection_object = object::address_to_object<collection::Collection>(
            expected_village_collection_address
        );
        assert!(
            collection::creator<collection::Collection>(village_collection_object) == 
                expected_resource_account_address,
            0
        );
        assert!(
            collection::name<collection::Collection>(village_collection_object) == 
                string::utf8(b"Village collection name"),
            0
        );
        assert!(
            collection::description<collection::Collection>(village_collection_object) == 
                string::utf8(b"Village collection description"),
            0
        );
        assert!(
            collection::uri<collection::Collection>(village_collection_object) == 
                string::utf8(b"Village collection URI"),
            0
        );
        assert!(
            option::is_some(&collection::count<collection::Collection>(village_collection_object)),
            0
        );
        assert!(
            option::contains(&collection::count<collection::Collection>(village_collection_object), &0),
            0
        );
    }

    #[test(admin = @overmind, user_1 = @0xCED, aptos_framework = @aptos_framework)]
    fun test_build_village_success(
        admin: &signer,
        user_1: &signer,
        aptos_framework: &signer
    ) acquires State, Village {
        let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        let aptos_framework_address = signer::address_of(aptos_framework);

        let aptos_framework = account::create_account_for_test(aptos_framework_address);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        init_module(admin);

        let expected_village_name = b"village_name";
        let expected_village_description = b"village_description";

        build_village(
            user_1,
            string::utf8(expected_village_name),
            string::utf8(expected_village_description)
        );

        let expected_resource_account_address = 
            account::create_resource_address(&admin_address, b"village builder");

        let state = borrow_global<State>(expected_resource_account_address);
        let villages = &state.villages;
        let create_village_events_counter = event::counter(&state.create_village_events);
        let upgrade_building_events_counter = event::counter(&state.upgrade_building_events);

        assert!(simple_map::length(villages) == 1, 1);
        assert!(create_village_events_counter == 1, 2);
        assert!(upgrade_building_events_counter == 0, 3);

        let village_address = simple_map::borrow(villages, &1);
        let village = borrow_global<Village>(*village_address);
        let actual_village_name = village.name;
        let actual_village_description = village.description;
        let buildings = village.buildings;

        assert!(actual_village_name == string::utf8(expected_village_name), 4);
        assert!(actual_village_description == string::utf8(expected_village_description), 5);
        let i = 1;
        loop {
            if (i > (simple_map::length(&buildings) as u8)) break;
            let building_level = simple_map::borrow(&buildings, &i);
            assert!(*building_level == 0, 6);
            i = i + 1;
        };
        assert!(
            simple_map::length(&buildings) == vector::length(&BUILDING_MAX_LEVELS),
            7
        );

        let expected_village_token_address = token::create_token_address(
            &expected_resource_account_address, 
            &string::utf8(b"Village collection name"),
            &string::utf8(b"Village #1: \"village_name\"")
        );
        let village_token_object = 
            object::address_to_object<token::Token>(expected_village_token_address);
        assert!(
            object::is_owner(village_token_object, user_1_address) == true, 
            0
        );
        assert!(
            token::creator(village_token_object) == expected_resource_account_address,
            0
        );
        assert!(
            token::name(village_token_object) == string::utf8(b"Village #1: \"village_name\""),
            0
        );
        assert!(
            token::description(village_token_object) == 
                string::utf8(b"Village collection description"),
            0
        );
        assert!(
            token::uri(village_token_object) == string::utf8(b"Village collection URI"),
            0
        );
        assert!(
            option::is_none(&token::royalty(village_token_object)),
            0
        );

        let expected_village_collection_address = collection::create_collection_address(
            &expected_resource_account_address, 
            &string::utf8(b"Village collection name")
        );
        let village_collection_object = object::address_to_object<collection::Collection>(
            expected_village_collection_address
        );
        assert!(
            option::is_some(&collection::count<collection::Collection>(village_collection_object)),
            0
        );
        assert!(
            option::contains(&collection::count<collection::Collection>(village_collection_object), &1),
            0
        );
    }

    #[test(admin = @overmind, user_1 = @0xCED, aptos_framework = @aptos_framework)]
    fun test_build_village_success_multiple_villages_same_user(
        admin: &signer,
        user_1: &signer,
        aptos_framework: &signer,
    ) acquires State, Village {
        let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        let aptos_framework_address = signer::address_of(aptos_framework);

        let aptos_framework = account::create_account_for_test(aptos_framework_address);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        init_module(admin);

        let expected_village_name_1 = b"village_name";
        let expected_village_description_1 = b"village_description";

        let expected_village_name_2 = b"village_name_2";
        let expected_village_description_2 = b"village_description_2";

        build_village(
            user_1,
            string::utf8(expected_village_name_1),
            string::utf8(expected_village_description_1)
        );

        build_village(
            user_1,
            string::utf8(expected_village_name_2),
            string::utf8(expected_village_description_2)
        );

        let expected_resource_account_address = 
            account::create_resource_address(&admin_address, b"village builder");

        let state = borrow_global<State>(expected_resource_account_address);
        let villages = &state.villages;
        let create_village_events_counter = event::counter(&state.create_village_events);
        let upgrade_building_events_counter = event::counter(&state.upgrade_building_events);

        assert!(simple_map::length(villages) == 2, 1);
        assert!(create_village_events_counter == 2, 2);
        assert!(upgrade_building_events_counter == 0, 3);

        let village_address_1 = simple_map::borrow(villages, &1);
        let village_1 = borrow_global<Village>(*village_address_1);
        let actual_village_name_1 = village_1.name;
        let actual_village_description_1 = village_1.description;
        let buildings_1 = village_1.buildings;

        assert!(actual_village_name_1 == string::utf8(expected_village_name_1), 4);
        assert!(actual_village_description_1 == string::utf8(expected_village_description_1), 5);
        let i = 1;
        loop {
            if (i > (simple_map::length(&buildings_1) as u8)) break;
            let building_level = simple_map::borrow(&buildings_1, &i);
            assert!(*building_level == 0, 6);
            i = i + 1;
        };
        assert!(
            simple_map::length(&buildings_1) == vector::length(&BUILDING_MAX_LEVELS),
            7
        );

        let expected_village_token_address_1 = token::create_token_address(
            &expected_resource_account_address, 
            &string::utf8(b"Village collection name"),
            &string::utf8(b"Village #1: \"village_name\"")
        );
        let village_token_object_1 = 
            object::address_to_object<token::Token>(expected_village_token_address_1);
        assert!(
            object::is_owner(village_token_object_1, user_1_address) == true, 
            0
        );
        assert!(
            token::creator(village_token_object_1) == expected_resource_account_address,
            0
        );
        assert!(
            token::name(village_token_object_1) == string::utf8(b"Village #1: \"village_name\""),
            0
        );
        assert!(
            token::description(village_token_object_1) == 
                string::utf8(b"Village collection description"),
            0
        );
        assert!(
            token::uri(village_token_object_1) == string::utf8(b"Village collection URI"),
            0
        );
        assert!(
            option::is_none(&token::royalty(village_token_object_1)),
            0
        );

        let village_address_2 = simple_map::borrow(villages, &2);
        let village_2 = borrow_global<Village>(*village_address_2);
        let actual_village_name_2 = village_2.name;
        let actual_village_description_2 = village_2.description;
        let buildings_2 = village_2.buildings;

        assert!(actual_village_name_2 == string::utf8(expected_village_name_2), 4);
        assert!(actual_village_description_2 == string::utf8(expected_village_description_2), 5);
        let i = 1;
        loop {
            if (i > (simple_map::length(&buildings_2) as u8)) break;
            let building_level = simple_map::borrow(&buildings_2, &i);
            assert!(*building_level == 0, 6);
            i = i + 1;
        };
        assert!(
            simple_map::length(&buildings_2) == vector::length(&BUILDING_MAX_LEVELS),
            7
        );

        let expected_village_token_address_2 = token::create_token_address(
            &expected_resource_account_address, 
            &string::utf8(b"Village collection name"),
            &string::utf8(b"Village #2: \"village_name_2\"")
        );
        let village_token_object_2 = 
            object::address_to_object<token::Token>(expected_village_token_address_2);
        assert!(
            object::is_owner(village_token_object_2, user_1_address) == true, 
            0
        );
        assert!(
            token::creator(village_token_object_2) == expected_resource_account_address,
            0
        );
        assert!(
            token::name(village_token_object_2) == string::utf8(b"Village #2: \"village_name_2\""),
            0
        );
        assert!(
            token::description(village_token_object_2) == 
                string::utf8(b"Village collection description"),
            0
        );
        assert!(
            token::uri(village_token_object_2) == string::utf8(b"Village collection URI"),
            0
        );
        assert!(
            option::is_none(&token::royalty(village_token_object_2)),
            0
        );

        let expected_village_collection_address = collection::create_collection_address(
            &expected_resource_account_address, 
            &string::utf8(b"Village collection name")
        );
        let village_collection_object = object::address_to_object<collection::Collection>(
            expected_village_collection_address
        );
        assert!(
            option::is_some(&collection::count<collection::Collection>(village_collection_object)),
            0
        );
        assert!(
            option::contains(&collection::count<collection::Collection>(village_collection_object), &2),
            0
        );
    }

    #[test(admin = @overmind, user_1 = @0xCED, user_2 = @0xDEC, aptos_framework = @aptos_framework)]
    fun test_build_village_success_multiple_villages_different_user(
        admin: &signer,
        user_1: &signer,
        user_2: &signer,
        aptos_framework: &signer,
    ) acquires State, Village {
        let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        let user_2_address = signer::address_of(user_2);
        let aptos_framework_address = signer::address_of(aptos_framework);

        let aptos_framework = account::create_account_for_test(aptos_framework_address);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);
        account::create_account_for_test(user_2_address);

        init_module(admin);

        let expected_village_name_1 = b"village_name";
        let expected_village_description_1 = b"village_description";

        let expected_village_name_2 = b"village_name_2";
        let expected_village_description_2 = b"village_description_2";

        build_village(
            user_1,
            string::utf8(expected_village_name_1),
            string::utf8(expected_village_description_1)
        );

        build_village(
            user_2,
            string::utf8(expected_village_name_2),
            string::utf8(expected_village_description_2)
        );

        let expected_resource_account_address = 
            account::create_resource_address(&admin_address, b"village builder");

        let state = borrow_global<State>(expected_resource_account_address);
        let villages = &state.villages;
        let create_village_events_counter = event::counter(&state.create_village_events);
        let upgrade_building_events_counter = event::counter(&state.upgrade_building_events);

        assert!(simple_map::length(villages) == 2, 1);
        assert!(create_village_events_counter == 2, 2);
        assert!(upgrade_building_events_counter == 0, 3);

        let village_address_1 = simple_map::borrow(villages, &1);
        let village_1 = borrow_global<Village>(*village_address_1);
        let actual_village_name_1 = village_1.name;
        let actual_village_description_1 = village_1.description;
        let buildings_1 = village_1.buildings;

        assert!(actual_village_name_1 == string::utf8(expected_village_name_1), 4);
        assert!(actual_village_description_1 == string::utf8(expected_village_description_1), 5);
        let i = 1;
        loop {
            if (i > (simple_map::length(&buildings_1) as u8)) break;
            let building_level = simple_map::borrow(&buildings_1, &i);
            assert!(*building_level == 0, 6);
            i = i + 1;
        };
        assert!(
            simple_map::length(&buildings_1) == vector::length(&BUILDING_MAX_LEVELS),
            7
        );

        let expected_village_token_address_1 = token::create_token_address(
            &expected_resource_account_address, 
            &string::utf8(b"Village collection name"),
            &string::utf8(b"Village #1: \"village_name\"")
        );
        let village_token_object_1 = 
            object::address_to_object<token::Token>(expected_village_token_address_1);
        assert!(
            object::is_owner(village_token_object_1, user_1_address) == true, 
            0
        );
        assert!(
            token::creator(village_token_object_1) == expected_resource_account_address,
            0
        );
        assert!(
            token::name(village_token_object_1) == string::utf8(b"Village #1: \"village_name\""),
            0
        );
        assert!(
            token::description(village_token_object_1) == 
                string::utf8(b"Village collection description"),
            0
        );
        assert!(
            token::uri(village_token_object_1) == string::utf8(b"Village collection URI"),
            0
        );
        assert!(
            option::is_none(&token::royalty(village_token_object_1)),
            0
        );

        let village_address_2 = simple_map::borrow(villages, &2);
        let village_2 = borrow_global<Village>(*village_address_2);
        let actual_village_name_2 = village_2.name;
        let actual_village_description_2 = village_2.description;
        let buildings_2 = village_2.buildings;

        assert!(actual_village_name_2 == string::utf8(expected_village_name_2), 4);
        assert!(actual_village_description_2 == string::utf8(expected_village_description_2), 5);
        let i = 1;
        loop {
            if (i > (simple_map::length(&buildings_2) as u8)) break;
            let building_level = simple_map::borrow(&buildings_2, &i);
            assert!(*building_level == 0, 6);
            i = i + 1;
        };
        assert!(
            simple_map::length(&buildings_2) == vector::length(&BUILDING_MAX_LEVELS),
            7
        );

        let expected_village_token_address_2 = token::create_token_address(
            &expected_resource_account_address, 
            &string::utf8(b"Village collection name"),
            &string::utf8(b"Village #2: \"village_name_2\"")
        );
        let village_token_object_2 = 
            object::address_to_object<token::Token>(expected_village_token_address_2);
        assert!(
            object::is_owner(village_token_object_2, user_2_address) == true, 
            0
        );
        assert!(
            token::creator(village_token_object_2) == expected_resource_account_address,
            0
        );
        assert!(
            token::name(village_token_object_2) == string::utf8(b"Village #2: \"village_name_2\""),
            0
        );
        assert!(
            token::description(village_token_object_2) == 
                string::utf8(b"Village collection description"),
            0
        );
        assert!(
            token::uri(village_token_object_2) == string::utf8(b"Village collection URI"),
            0
        );
        assert!(
            option::is_none(&token::royalty(village_token_object_2)),
            0
        );

        let expected_village_collection_address = collection::create_collection_address(
            &expected_resource_account_address, 
            &string::utf8(b"Village collection name")
        );
        let village_collection_object = object::address_to_object<collection::Collection>(
            expected_village_collection_address
        );
        assert!(
            option::is_some(&collection::count<collection::Collection>(village_collection_object)),
            0
        );
        assert!(
            option::contains(&collection::count<collection::Collection>(village_collection_object), &2),
            0
        );
    }

    #[test(admin = @overmind, user_1 = @0xCED, aptos_framework = @aptos_framework)]
    fun test_upgrade_building_success_one_building(
        admin: &signer,
        user_1: &signer,
        aptos_framework: &signer,
    ) acquires State, Village {
        let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        let aptos_framework_address = signer::address_of(aptos_framework);

        let aptos_framework = account::create_account_for_test(aptos_framework_address);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        coin::register<AptosCoin>(user_1);

        init_module(admin);

        let expected_village_name = b"village_name";
        let expected_village_description = b"village_description";

        build_village(
            user_1,
            string::utf8(expected_village_name),
            string::utf8(expected_village_description)
        );

        let aptos_amount = 100000000;
        aptos_coin::mint(&aptos_framework, user_1_address, aptos_amount);
        let building_to_upgrade = 1;
        upgrade_building(user_1, 1, building_to_upgrade);

        let expected_resource_account_address = 
            account::create_resource_address(&admin_address, b"village builder");

        let state = borrow_global<State>(expected_resource_account_address);
        let villages = &state.villages;
        let create_village_events_counter = event::counter(&state.create_village_events);
        let upgrade_building_events_counter = event::counter(&state.upgrade_building_events);
        assert!(simple_map::length(villages) == 1, 1);
        assert!(create_village_events_counter == 1, 2);
        assert!(upgrade_building_events_counter == 1, 7);

        let village_address = simple_map::borrow(villages, &1);
        let village = borrow_global<Village>(*village_address);
        let buildings = village.buildings;

        let building_level = simple_map::borrow(&buildings, &building_to_upgrade);
        assert!(*building_level == 1, 5);

        assert!(
            village.building_upgrade_unlock_timestamp_seconds == 
                timestamp::now_seconds() + get_building_level_upgrade_duration(building_to_upgrade),
            6
        );

        let total_upgrade_cost = get_building_upgrade_cost(building_to_upgrade);
        assert!(coin::balance<AptosCoin>(user_1_address) == aptos_amount - total_upgrade_cost, 5);
        assert!(coin::balance<AptosCoin>(expected_resource_account_address) == total_upgrade_cost, 6);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(admin = @overmind, user_1 = @0xCED, aptos_framework = @aptos_framework)]
    fun test_upgrade_building_success_multiple_buildings(
        admin: &signer,
        user_1: &signer,
        aptos_framework: &signer,
    ) acquires State, Village {
        let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        let aptos_framework_address = signer::address_of(aptos_framework);

        let aptos_framework = account::create_account_for_test(aptos_framework_address);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        coin::register<AptosCoin>(user_1);

        init_module(admin);

        let expected_village_name = b"village_name";
        let expected_village_description = b"village_description";

        build_village(
            user_1,
            string::utf8(expected_village_name),
            string::utf8(expected_village_description)
        );

        let aptos_amount = 100000000;
        aptos_coin::mint(&aptos_framework, user_1_address, aptos_amount);


        let building_to_upgrade_1 = 1;
        let building_to_upgrade_2 = 4;
        let building_to_upgrade_3 = 1;
        let building_to_upgrade_4 = 9;
        
        upgrade_building(user_1, 1, building_to_upgrade_1);
        timestamp::fast_forward_seconds(get_building_level_upgrade_duration(1));
        upgrade_building(user_1, 1, building_to_upgrade_2);
        timestamp::fast_forward_seconds(get_building_level_upgrade_duration(1));
        upgrade_building(user_1, 1, building_to_upgrade_3);
        timestamp::fast_forward_seconds(get_building_level_upgrade_duration(2));
        upgrade_building(user_1, 1, building_to_upgrade_4);


        let expected_resource_account_address = 
            account::create_resource_address(&admin_address, b"village builder");

        let state = borrow_global<State>(expected_resource_account_address);
        let villages = &state.villages;
        let create_village_events_counter = event::counter(&state.create_village_events);
        let upgrade_building_events_counter = event::counter(&state.upgrade_building_events);
        assert!(simple_map::length(villages) == 1, 1);
        assert!(create_village_events_counter == 1, 2);
        assert!(upgrade_building_events_counter == 4, 7);

        let village_address = simple_map::borrow(villages, &1);
        let village = borrow_global<Village>(*village_address);
        let buildings = village.buildings;

        let building_1_level = simple_map::borrow(&buildings, &building_to_upgrade_1);
        let building_2_level = simple_map::borrow(&buildings, &building_to_upgrade_2);
        let building_4_level = simple_map::borrow(&buildings, &building_to_upgrade_4);
        assert!(*building_1_level == 2, 5);
        assert!(*building_2_level == 1, 5);
        assert!(*building_4_level == 1, 5);

        assert!(
            village.building_upgrade_unlock_timestamp_seconds == 
                timestamp::now_seconds() + get_building_level_upgrade_duration(1),
            6
        );

        let total_upgrade_cost = 
            get_building_upgrade_cost(building_to_upgrade_1) + 
            get_building_upgrade_cost(building_to_upgrade_2) + 
            get_building_upgrade_cost(building_to_upgrade_3) + 
            get_building_upgrade_cost(building_to_upgrade_4);
        assert!(coin::balance<AptosCoin>(user_1_address) == aptos_amount - total_upgrade_cost, 5);
        assert!(coin::balance<AptosCoin>(expected_resource_account_address) == total_upgrade_cost, 6);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(admin = @overmind, account = @0xCED, aptos_framework = @aptos_framework)]
    fun test_upgrade_building_success_with_requirements(
        admin: &signer,
        account: &signer,
        aptos_framework: &signer,
    ) acquires State, Village {
        let admin_address = signer::address_of(admin);
        let account_address = signer::address_of(account);
        let aptos_framework_address = signer::address_of(aptos_framework);

        let aptos_framework = account::create_account_for_test(aptos_framework_address);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        account::create_account_for_test(admin_address);
        account::create_account_for_test(account_address);

        let aptos_amount = 100000000;
        coin::register<AptosCoin>(account);
        aptos_coin::mint(&aptos_framework, account_address, aptos_amount);

        init_module(admin);

        let expected_village_name = b"village_name";
        let expected_village_description = b"village_description";

        build_village(
            account,
            string::utf8(expected_village_name),
            string::utf8(expected_village_description)
        );

        upgrade_building(account, 1, BUILDING_ID_TOWN_HALL);
        timestamp::fast_forward_seconds(2000);
        upgrade_building(account, 1, BUILDING_ID_TOWN_HALL);
        timestamp::fast_forward_seconds(2000);
        upgrade_building(account, 1, BUILDING_ID_BARRACKS);

        let expected_resource_account_address = 
            account::create_resource_address(&admin_address, b"village builder");

        let state = borrow_global<State>(expected_resource_account_address);
        let villages = &state.villages;
        let create_village_events_counter = event::counter(&state.create_village_events);
        let upgrade_building_events_counter = event::counter(&state.upgrade_building_events);

        assert!(simple_map::length(villages) == 1, 1);
        assert!(create_village_events_counter == 1, 2);
        assert!(upgrade_building_events_counter == 3, 7);

        let village_address = simple_map::borrow(villages, &1);
        let village = borrow_global<Village>(*village_address);
        let actual_village_name = village.name;
        let actual_village_description = village.description;
        let buildings = village.buildings;

        assert!(actual_village_name == string::utf8(expected_village_name), 3);
        assert!(actual_village_description == string::utf8(expected_village_description), 4);
        let required_building_level = simple_map::borrow(&buildings, &1);
        assert!(*required_building_level == 2, 5);
        let building_level = simple_map::borrow(&buildings, &3);
        assert!(*building_level == 1, 6);

        let total_upgrade_cost = get_building_upgrade_cost(1)
            + get_building_upgrade_cost(1)
            + get_building_upgrade_cost(3);

        assert!(coin::balance<AptosCoin>(account_address) == aptos_amount - total_upgrade_cost, 5);
        assert!(coin::balance<AptosCoin>(expected_resource_account_address) == total_upgrade_cost, 6);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(admin = @overmind, account = @0xCED, aptos_framework = @aptos_framework)]
    fun test_upgrade_building_success_multiple_villages_at_the_same_time(
        admin: &signer,
        account: &signer,
        aptos_framework: &signer,
    ) acquires State, Village {
        let admin_address = signer::address_of(admin);
        let account_address = signer::address_of(account);
        let aptos_framework_address = signer::address_of(aptos_framework);

        let aptos_framework = account::create_account_for_test(aptos_framework_address);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        account::create_account_for_test(admin_address);
        account::create_account_for_test(account_address);

        let aptos_amount = 100000000;
        coin::register<AptosCoin>(account);
        aptos_coin::mint(&aptos_framework, account_address, aptos_amount);

        init_module(admin);

        let expected_village_name = b"village_name";
        let expected_village_description = b"village_description";

        build_village(
            account,
            string::utf8(expected_village_name),
            string::utf8(expected_village_description)
        );

        build_village(
            account,
            string::utf8(expected_village_name),
            string::utf8(expected_village_description)
        );

        upgrade_building(account, 1, BUILDING_ID_TOWN_HALL);
        upgrade_building(account, 2, BUILDING_ID_TOWN_HALL);
        timestamp::fast_forward_seconds(2000);
        upgrade_building(account, 1, BUILDING_ID_TOWN_HALL);
        upgrade_building(account, 2, BUILDING_ID_TOWN_HALL);
        timestamp::fast_forward_seconds(2000);
        upgrade_building(account, 1, BUILDING_ID_BARRACKS);
        upgrade_building(account, 2, BUILDING_ID_BARRACKS);

        let expected_resource_account_address = 
            account::create_resource_address(&admin_address, b"village builder");

        let state = borrow_global<State>(expected_resource_account_address);
        let villages = &state.villages;
        let create_village_events_counter = event::counter(&state.create_village_events);
        let upgrade_building_events_counter = event::counter(&state.upgrade_building_events);

        assert!(simple_map::length(villages) == 2, 1);
        assert!(create_village_events_counter == 2, 2);
        assert!(upgrade_building_events_counter == 6, 7);

        let village_address = simple_map::borrow(villages, &1);
        let village = borrow_global<Village>(*village_address);
        let actual_village_name = village.name;
        let actual_village_description = village.description;
        let buildings = village.buildings;

        assert!(actual_village_name == string::utf8(expected_village_name), 3);
        assert!(actual_village_description == string::utf8(expected_village_description), 4);
        let required_building_level = simple_map::borrow(&buildings, &1);
        assert!(*required_building_level == 2, 5);
        let building_level = simple_map::borrow(&buildings, &3);
        assert!(*building_level == 1, 6);

        let village_address = simple_map::borrow(villages, &2);
        let village = borrow_global<Village>(*village_address);
        let actual_village_name = village.name;
        let actual_village_description = village.description;
        let buildings = village.buildings;

        assert!(actual_village_name == string::utf8(expected_village_name), 3);
        assert!(actual_village_description == string::utf8(expected_village_description), 4);
        let required_building_level = simple_map::borrow(&buildings, &1);
        assert!(*required_building_level == 2, 5);
        let building_level = simple_map::borrow(&buildings, &3);
        assert!(*building_level == 1, 6);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(admin = @overmind, account = @0xCED, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_upgrade_building_failure_building_does_not_exist(
        admin: &signer,
        account: &signer,
        aptos_framework: &signer,
    ) acquires State, Village {
        let admin_address = signer::address_of(admin);
        let account_address = signer::address_of(account);
        let aptos_framework_address = signer::address_of(aptos_framework);

        let aptos_framework = account::create_account_for_test(aptos_framework_address);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        account::create_account_for_test(admin_address);
        account::create_account_for_test(account_address);

        let aptos_amount = 100000000;
        coin::register<AptosCoin>(account);
        aptos_coin::mint(&aptos_framework, account_address, aptos_amount);

        init_module(admin);

        let expected_village_name = b"village_name";
        let expected_village_description = b"village_description";

        build_village(
            account,
            string::utf8(expected_village_name),
            string::utf8(expected_village_description)
        );

        upgrade_building(account, 1, 255);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(admin = @overmind, account = @0xCED, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_upgrade_building_failure_village_does_not_exist(
        admin: &signer,
        account: &signer,
        aptos_framework: &signer,
    ) acquires State, Village {
        let admin_address = signer::address_of(admin);
        let account_address = signer::address_of(account);
        let aptos_framework_address = signer::address_of(aptos_framework);

        let aptos_framework = account::create_account_for_test(aptos_framework_address);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        account::create_account_for_test(admin_address);
        account::create_account_for_test(account_address);

        init_module(admin);

        upgrade_building(account, 1, BUILDING_ID_TOWN_HALL);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(admin = @overmind, account = @0xCED, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_upgrade_building_failure_user_not_village_owner(
        admin: &signer,
        account: &signer,
        aptos_framework: &signer,
    ) acquires State, Village {
        let admin_address = signer::address_of(admin);
        let account_address = signer::address_of(account);
        let aptos_framework_address = signer::address_of(aptos_framework);

        let aptos_framework = account::create_account_for_test(aptos_framework_address);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        account::create_account_for_test(admin_address);
        account::create_account_for_test(account_address);

        init_module(admin);

        let expected_village_name = b"village_name";
        let expected_village_description = b"village_description";

        build_village(
            admin,
            string::utf8(expected_village_name),
            string::utf8(expected_village_description)
        );

        coin::register<AptosCoin>(account);
        let aptos_amount = 100000000;
        aptos_coin::mint(&aptos_framework, account_address, aptos_amount);
        upgrade_building(account, 1, BUILDING_ID_TOWN_HALL);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(admin = @overmind, account = @0xCED, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_upgrade_building_failure_max_level_reached(
        admin: &signer,
        account: &signer,
        aptos_framework: &signer,
    ) acquires State, Village {
        let admin_address = signer::address_of(admin);
        let account_address = signer::address_of(account);
        let aptos_framework_address = signer::address_of(aptos_framework);

        let aptos_framework = account::create_account_for_test(aptos_framework_address);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        account::create_account_for_test(admin_address);
        account::create_account_for_test(account_address);

        let aptos_amount = 100000000;
        coin::register<AptosCoin>(account);
        aptos_coin::mint(&aptos_framework, account_address, aptos_amount);

        init_module(admin);

        let expected_village_name = b"village_name";
        let expected_village_description = b"village_description";

        build_village(
            account,
            string::utf8(expected_village_name),
            string::utf8(expected_village_description)
        );

        upgrade_building(account, 1, BUILDING_ID_TOWN_HALL);
        timestamp::fast_forward_seconds(2000);
        upgrade_building(account, 1, BUILDING_ID_TOWN_HALL);
        timestamp::fast_forward_seconds(2000);
        upgrade_building(account, 1, BUILDING_ID_TOWN_HALL);
        timestamp::fast_forward_seconds(2000);
        upgrade_building(account, 1, BUILDING_ID_HEADQUARTERS);
        timestamp::fast_forward_seconds(2000);
        upgrade_building(account, 1, BUILDING_ID_HEADQUARTERS);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(admin = @overmind, account = @0xCED, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_upgrade_building_failure_requirements_not_met(
        admin: &signer,
        account: &signer,
        aptos_framework: &signer,
    ) acquires State, Village {
        let admin_address = signer::address_of(admin);
        let account_address = signer::address_of(account);
        let aptos_framework_address = signer::address_of(aptos_framework);

        let aptos_framework = account::create_account_for_test(aptos_framework_address);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        account::create_account_for_test(admin_address);
        account::create_account_for_test(account_address);

        init_module(admin);

        let expected_village_name = b"village_name";
        let expected_village_description = b"village_description";

        build_village(
            account,
            string::utf8(expected_village_name),
            string::utf8(expected_village_description)
        );

        let aptos_amount = 100000000;
        coin::register<AptosCoin>(account);
        aptos_coin::mint(&aptos_framework, account_address, aptos_amount);
        upgrade_building(account, 1, BUILDING_ID_BARRACKS);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(admin = @overmind, account = @0xCED, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_upgrade_building_failure_upgrading_not_finished(
        admin: &signer,
        account: &signer,
        aptos_framework: &signer,
    ) acquires State, Village {
        let admin_address = signer::address_of(admin);
        let account_address = signer::address_of(account);
        let aptos_framework_address = signer::address_of(aptos_framework);

        let aptos_framework = account::create_account_for_test(aptos_framework_address);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        account::create_account_for_test(admin_address);
        account::create_account_for_test(account_address);

        let aptos_amount = 100000000;
        coin::register<AptosCoin>(account);
        aptos_coin::mint(&aptos_framework, account_address, aptos_amount);

        init_module(admin);

        let expected_village_name = b"village_name";
        let expected_village_description = b"village_description";

        build_village(
            account,
            string::utf8(expected_village_name),
            string::utf8(expected_village_description)
        );

        upgrade_building(account, 1, BUILDING_ID_TOWN_HALL);
        timestamp::fast_forward_seconds(2000);
        upgrade_building(account, 1, BUILDING_ID_TOWN_HALL);
        timestamp::fast_forward_seconds(50);
        upgrade_building(account, 1, BUILDING_ID_TOWN_HALL);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(admin = @overmind, account = @0xCED, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_upgrade_building_failure_not_enough_funds(
        admin: &signer,
        account: &signer,
        aptos_framework: &signer,
    ) acquires State, Village {
        let admin_address = signer::address_of(admin);
        let account_address = signer::address_of(account);
        let aptos_framework_address = signer::address_of(aptos_framework);

        let aptos_framework = account::create_account_for_test(aptos_framework_address);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        account::create_account_for_test(admin_address);
        account::create_account_for_test(account_address);

        let aptos_amount = 500;
        coin::register<AptosCoin>(account);
        aptos_coin::mint(&aptos_framework, account_address, aptos_amount);

        init_module(admin);

        let expected_village_name = b"village_name";
        let expected_village_description = b"village_description";

        build_village(
            account,
            string::utf8(expected_village_name),
            string::utf8(expected_village_description)
        );

        upgrade_building(account, 1, BUILDING_ID_TOWN_HALL);
        timestamp::fast_forward_seconds(2000);
        upgrade_building(account, 1, BUILDING_ID_TOWN_HALL);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test()]
    fun test_get_building_upgrade_cost_success_1() {
        assert!(
            get_building_upgrade_cost(1) == 500,
            1
        );
    }

    #[test()]
    fun test_get_building_upgrade_cost_success_2() {
        assert!(
            get_building_upgrade_cost(2) == 10000,
            1
        );
    }

    #[test()]
    fun test_get_building_upgrade_cost_success_3() {
        assert!(
            get_building_upgrade_cost(3) == 500,
            1
        );
    }

    #[test()]
    fun test_get_building_upgrade_cost_success_4() {
        assert!(
            get_building_upgrade_cost(4) == 600,
            1
        );
    }

    #[test()]
    fun test_get_building_upgrade_cost_success_5() {
        assert!(
            get_building_upgrade_cost(5) == 600,
            1
        );
    }

    #[test()]
    fun test_get_building_upgrade_cost_success_6() {
        assert!(
            get_building_upgrade_cost(6) == 600,
            1
        );
    }

    #[test()]
    fun test_get_building_upgrade_cost_success_7() {
        assert!(
            get_building_upgrade_cost(7) == 100,
            1
        );
    }

    #[test()]
    fun test_get_building_upgrade_cost_success_8() {
        assert!(
            get_building_upgrade_cost(8) == 600,
            1
        );
    }

    #[test()]
    fun test_get_building_upgrade_cost_success_9() {
        assert!(
            get_building_upgrade_cost(9) == 100,
            1
        );
    }

    #[test()]
    fun test_get_building_upgrade_cost_success_10() {
        assert!(
            get_building_upgrade_cost(10) == 10000,
            1
        );
    }

    #[test()]
    fun test_get_building_upgrade_cost_success_11() {
        assert!(
            get_building_upgrade_cost(11) == 5000,
            1
        );
    }

    #[test()]
    fun test_get_building_upgrade_cost_success_12() {
        assert!(
            get_building_upgrade_cost(12) == 10000,
            1
        );
    }

    #[test()]
    fun test_get_building_level_upgrade_duration_success_1() {
        assert!(
            get_building_level_upgrade_duration(1) == 60,
            1
        );
    }

    #[test()]
    fun test_get_building_level_upgrade_duration_success_2() {
        assert!(
            get_building_level_upgrade_duration(2) == 120,
            1
        );
    }

    #[test()]
    fun test_get_building_level_upgrade_duration_success_3() {
        assert!(
            get_building_level_upgrade_duration(3) == 200,
            1
        );
    }

    #[test()]
    fun test_get_building_level_upgrade_duration_success_4() {
        assert!(
            get_building_level_upgrade_duration(4) == 300,
            1
        );
    }

    #[test()]
    fun test_get_building_level_upgrade_duration_success_5() {
        assert!(
            get_building_level_upgrade_duration(5) == 500,
            1
        );
    }

    #[test()]
    fun test_get_building_level_upgrade_duration_success_6() {
        assert!(
            get_building_level_upgrade_duration(6) == 700,
            1
        );
    }

    #[test()]
    fun test_get_building_level_upgrade_duration_success_7() {
        assert!(
            get_building_level_upgrade_duration(7) == 900,
            1
        );
    }

    #[test()]
    fun test_get_building_level_upgrade_duration_success_8() {
        assert!(
            get_building_level_upgrade_duration(8) == 1000,
            1
        );
    }

    #[test()]
    fun test_get_building_level_upgrade_duration_success_9() {
        assert!(
            get_building_level_upgrade_duration(9) == 1500,
            1
        );
    }

    #[test()]
    fun test_get_building_level_upgrade_duration_success_10() {
        assert!(
            get_building_level_upgrade_duration(10) == 2000,
            1
        );
    }

    #[test()]
    fun test_get_building_requirements_success_1() {
        let (required_building_id, required_building_level) = get_building_requirements(1);
        assert!(
            required_building_id == 0,
            1
        );
        assert!(
            required_building_level == 0,
            2
        );
    }

    #[test()]
    fun test_get_building_requirements_success_2() {
        let (required_building_id, required_building_level) = get_building_requirements(2);
        assert!(
            required_building_id == 1,
            1
        );
        assert!(
            required_building_level == 3,
            2
        );
    }

    #[test()]
    fun test_get_building_requirements_success_3() {
        let (required_building_id, required_building_level) = get_building_requirements(3);
        assert!(
            required_building_id == 1,
            1
        );
        assert!(
            required_building_level == 2,
            2
        );
    }

    #[test()]
    fun test_get_building_requirements_success_4() {
        let (required_building_id, required_building_level) = get_building_requirements(4);
        assert!(
            required_building_id == 0,
            1
        );
        assert!(
            required_building_level == 0,
            2
        );
    }

    #[test()]
    fun test_get_building_requirements_success_5() {
        let (required_building_id, required_building_level) = get_building_requirements(5);
        assert!(
            required_building_id == 0,
            1
        );
        assert!(
            required_building_level == 0,
            2
        );
    }

    #[test()]
    fun test_get_building_requirements_success_6() {
        let (required_building_id, required_building_level) = get_building_requirements(6);
        assert!(
            required_building_id == 0,
            1
        );
        assert!(
            required_building_level == 0,
            2
        );
    }

    #[test()]
    fun test_get_building_requirements_success_7() {
        let (required_building_id, required_building_level) = get_building_requirements(7);
        assert!(
            required_building_id == 0,
            1
        );
        assert!(
            required_building_level == 0,
            2
        );
    }

    #[test()]
    fun test_get_building_requirements_success_8() {
        let (required_building_id, required_building_level) = get_building_requirements(8);
        assert!(
            required_building_id == 3,
            1
        );
        assert!(
            required_building_level == 3,
            2
        );
    }

    #[test()]
    fun test_get_building_requirements_success_9() {
        let (required_building_id, required_building_level) = get_building_requirements(9);
        assert!(
            required_building_id == 0,
            1
        );
        assert!(
            required_building_level == 0,
            2
        );
    }

    #[test()]
    fun test_get_building_requirements_success_10() {
        let (required_building_id, required_building_level) = get_building_requirements(10);
        assert!(
            required_building_id == 0,
            1
        );
        assert!(
            required_building_level == 0,
            2
        );
    }

    #[test()]
    fun test_get_building_requirements_success_11() {
        let (required_building_id, required_building_level) = get_building_requirements(11);
        assert!(
            required_building_id == 3,
            1
        );
        assert!(
            required_building_level == 1,
            2
        );
    }

    #[test()]
    fun test_get_building_requirements_success_12() {
        let (required_building_id, required_building_level) = get_building_requirements(12);
        assert!(
            required_building_id == 1,
            1
        );
        assert!(
            required_building_level == 5,
            2
        );
    }

    #[test()]
    fun test_get_building_max_level_success_1() {
        assert!(
            get_building_max_level(1) == 5,
            1
        );
    }

    #[test()]
    fun test_get_building_max_level_success_2() {
        assert!(
            get_building_max_level(2) == 1,
            1
        );
    }

    #[test()]
    fun test_get_building_max_level_success_3() {
        assert!(
            get_building_max_level(3) == 5,
            1
        );
    }

    #[test()]
    fun test_get_building_max_level_success_4() {
        assert!(
            get_building_max_level(4) == 6,
            1
        );
    }

    #[test()]
    fun test_get_building_max_level_success_5() {
        assert!(
            get_building_max_level(5) == 6,
            1
        );
    }

    #[test()]
    fun test_get_building_max_level_success_6() {
        assert!(
            get_building_max_level(6) == 6,
            1
        );
    }

    #[test()]
    fun test_get_building_max_level_success_7() {
        assert!(
            get_building_max_level(7) == 10,
            1
        );
    }

    #[test()]
    fun test_get_building_max_level_success_8() {
        assert!(
            get_building_max_level(8) == 6,
            1
        );
    }

    #[test()]
    fun test_get_building_max_level_success_9() {
        assert!(
            get_building_max_level(9) == 10,
            1
        );
    }

    #[test()]
    fun test_get_building_max_level_success_10() {
        assert!(
            get_building_max_level(10) == 1,
            1
        );
    }

    #[test()]
    fun test_get_building_max_level_success_11() {
        assert!(
            get_building_max_level(11) == 1,
            1
        );
    }

    #[test()]
    fun test_get_building_max_level_success_12() {
        assert!(
            get_building_max_level(12) == 1,
            1
        );
    }
}
