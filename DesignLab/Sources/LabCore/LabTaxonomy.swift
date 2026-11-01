// Generated once from production category_taxonomy.json (plain data copy). Order is meaningful.
public enum LabTaxonomy {
    /// category > subcategory > item groups, in production order.
    public static let tree: [(category: String, subcategories: [(name: String, itemGroups: [String])])] = [
        ("Food", [
            ("Vegetables", ["Tomatoes", "Leafy Greens", "Root Vegetables", "Peppers", "Onions & Garlic", "Mushrooms", "Cucumbers, Squash & Eggplant", "Herbs & Aromatics", "Cabbage & Brassicas", "Other Vegetables"]),
            ("Fruits", ["Berries", "Grapes", "Citrus", "Bananas", "Apples & Pears", "Tropical & Stone Fruit", "Other Fruits"]),
            ("Dairy & Eggs", ["Milk", "Cheese", "Cream Cheese", "Yogurt, Skyr & Quark", "Eggs", "Butter & Cream"]),
            ("Meat & Fish", ["Poultry", "Beef & Pork", "Ham & Cured Meat", "Fish & Seafood", "Cold Cuts"]),
            ("Bakery", ["Bread", "Pastries"]),
            ("Pantry", ["Pasta & Rice", "Cereals & Muesli", "Legumes", "Canned Goods", "Sauces & Condiments", "Spices", "Baking & Sugar", "Spreads", "Oils & Vinegar"]),
            ("Beverages", ["Water", "Soft Drinks", "Juice", "Coffee & Tea", "Beer", "Wine", "Spirits"]),
            ("Snacks & Sweets", ["Chips & Snacks", "Chocolate & Candy", "Cookies", "Nuts, Seeds & Dried Fruit"]),
            ("Frozen & Ready Meals", ["Frozen Pizza", "Ready Meals", "Frozen Fruit & Vegetables", "Ice Cream"]),
        ]),
        ("Household", [
            ("Cleaning", ["Laundry", "Surface Cleaners", "Dishwashing"]),
            ("Paper Goods", ["Toilet Paper", "Kitchen Roll", "Tissues"]),
            ("Household Goods", ["Foils, Baking Paper & Bin Bags", "Household Goods & Batteries"]),
        ]),
        ("Personal Care", [
            ("Hygiene", ["Shower & Bath", "Oral Care", "Deodorant"]),
            ("Cosmetics", ["Skincare", "Haircare", "Makeup", "Sun Care"]),
        ]),
        ("Other", [
            ("Pharmacy", ["First Aid & Plasters", "Supplements", "General"]),
            ("Pet Supplies", ["General"]),
            ("Deposits & Refunds", ["Pfand", "Returns & Refunds"]),
            ("Not a product", ["Receipt text"]),
            ("Miscellaneous", ["General"]),
        ]),
    ]

    public static var categoryNames: [String] { tree.map(\.category) }
    public static func subcategoryNames(in category: String) -> [String] {
        tree.first { $0.category == category }?.subcategories.map(\.name) ?? []
    }
    public static func itemGroups(category: String, subcategory: String) -> [String] {
        tree.first { $0.category == category }?.subcategories.first { $0.name == subcategory }?.itemGroups ?? ["General"]
    }
}
