package com.robinrossner.receipts.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class TaxonomyTest {
    private val taxonomy = bundledTaxonomy()
    private val pets = TaxonomyPath("Household", "Pets", "Pet Food")

    @Test
    fun theServersMergeRulesAreFollowed() {
        val t = taxonomy.adding(
            listOf(
                TaxonomyPath("Household", "Pets", "Pet Food"), TaxonomyPath("household", "pets", "Cat Litter"),
                TaxonomyPath("Household", "Cleaning", "Windows"), TaxonomyPath("Garden", "Plants", "Seeds"),
                TaxonomyPath("Food", "Pantry", "legumes"),
            ),
        )
        assertEquals(listOf("Pet Food", "Cat Litter"), t.itemGroups("Household", "Pets"))
        assertEquals("Windows", t.itemGroups("Household", "Cleaning").last())
        assertEquals("a new category goes last", "Garden", t.categoryNames().last())
        assertEquals("an existing path changes nothing", 1, t.itemGroups("Food", "Pantry").count { it.lowercase() == "legumes" })
        assertSame("no paths: the same instance", taxonomy, taxonomy.adding(emptyList()))
        assertEquals(taxonomy.categoryNames(), taxonomy.adding(emptyList()).categoryNames())
        assertFalse("the original is not changed", taxonomy.contains(pets))
    }

    @Test
    fun anAddedCategoryShowsInEveryPickerLevel() {
        val merged = taxonomy.adding(listOf(TaxonomyPath("Pets & Animals", "Dogs", "Food")))
        assertTrue("Pets & Animals" in merged.categoryNames())
        assertEquals(listOf("Dogs"), merged.subcategoryNames("Pets & Animals"))
        assertEquals(listOf("Food"), merged.itemGroups("Pets & Animals", "Dogs"))
    }

    @Test
    fun canonicalLookupsIgnoreCaseAndReturnTheTaxonomysSpelling() {
        assertEquals(TaxonomyPath("Food", "Dairy & Eggs", "Milk"), taxonomy.canonicalPath(TaxonomyPath("food", "dairy & eggs", "MILK")))
        assertNull(taxonomy.canonicalPath(pets))
        assertEquals("Food", taxonomy.canonicalCategory("fOOD"))
        assertNull(taxonomy.canonicalCategory("Nope"))
        assertEquals("Dairy & Eggs", taxonomy.canonicalSubcategory("DAIRY & eggs", "food"))
        assertNull(taxonomy.canonicalSubcategory("Pets", "Food"))
        assertTrue("contains is case-sensitive, as the server's check", taxonomy.contains(TaxonomyPath("Food", "Dairy & Eggs", "Milk")))
        assertFalse(taxonomy.contains(TaxonomyPath("food", "dairy & eggs", "milk")))
        assertTrue(taxonomy.contains(Taxonomy.FALLBACK))
    }

    @Test
    fun pathLabels() {
        assertEquals("A > B > C", TaxonomyPath("A", "B", "C").label)
        assertEquals(TaxonomyPath("Food", "Pantry", "Legumes"), TaxonomyPath.fromLabel("Food > Pantry > Legumes"))
        assertNull(TaxonomyPath.fromLabel("Food > Pantry"))
        assertNull(TaxonomyPath.fromLabel("A > B > C > D"))
        assertNull(TaxonomyPath.fromLabel("A>B>C"))
    }

    @Test
    fun invalidCategoryNamesAreRefusedWithTheMessagesTheUiShows() {
        assertEquals("The category name is empty.", Taxonomy.additionProblem(TaxonomyPath("", "Pets", "Pet Food")))
        assertEquals("The subcategory name must not contain \">\".", Taxonomy.additionProblem(TaxonomyPath("Household", "A > B", "x")))
        assertEquals("The item group name is longer than 60 characters.", Taxonomy.additionProblem(TaxonomyPath("Household", "Pets", "x".repeat(61))))
        assertNull(Taxonomy.additionProblem(TaxonomyPath("Household", "Pets", "x".repeat(60))))
        assertEquals("The item group name is empty.", Taxonomy.additionProblem(TaxonomyPath("Household", "Pets", "  ")))
        assertEquals("The category name has leading or trailing spaces.", Taxonomy.additionProblem(TaxonomyPath(" Household", "Pets", "Pet Food")))
        assertEquals("The subcategory name has control characters.", Taxonomy.additionProblem(TaxonomyPath("Household", "Pe\u0007ts", "Pet Food")))
        assertEquals("The item group name has control characters.", Taxonomy.additionProblem(TaxonomyPath("Household", "Pets", "Pet\nFood")))
        // 61 code points of an emoji outside the BMP are 61 characters, not 122
        assertNull(Taxonomy.additionProblem(TaxonomyPath("Household", "Pets", "🐕".repeat(60))))
        assertNotNull(Taxonomy.additionProblem(TaxonomyPath("Household", "Pets", "🐕".repeat(61))))
        assertNull(Taxonomy.additionProblem(pets))
    }

    // ---- keyword rules ----

    @Test
    fun keywordRulesAreLoadedFromTheBundledFile() {
        assertEquals(TaxonomyPath("Food", "Pantry", "Cereals & Muesli"), taxonomy.keywordPath("haferflocken zart"))
        assertNull("exclude wins", taxonomy.keywordPath("haferflocken riegel"))
        assertEquals(TaxonomyPath("Other", "Not a product", "Receipt text"), taxonomy.keywordPath("summe"))
        assertEquals(TaxonomyPath("Other", "Not a product", "Receipt text"), taxonomy.keywordPath("zwischensumme"))
        assertEquals(TaxonomyPath("Other", "Not a product", "Receipt text"), taxonomy.keywordPath("42,54 eur"))
        assertNull("the receipt-text rule is anchored", taxonomy.keywordPath("summe tee"))
        assertEquals("matching is case-insensitive", TaxonomyPath("Food", "Pantry", "Cereals & Muesli"), taxonomy.keywordPath("Bio MÜSLI"))
        assertNull(taxonomy.keywordPath("vollmilch"))
    }

    @Test
    fun theFirstMatchingRuleWins() {
        val t = Taxonomy.parse(
            """{"categories": {"A": {"B": ["C", "D"]}},
                "keyword_rules": [
                  {"pattern": "foo", "exclude": "bar", "path": "A > B > C"},
                  {"pattern": "foo", "path": "A > B > D"},
                  {"pattern": "(unclosed", "path": "A > B > C"},
                  {"pattern": "baz", "path": "not a path"}]}""",
        )
        assertEquals(TaxonomyPath("A", "B", "C"), t.keywordPath("foo"))
        assertEquals("exclude skips to the next rule", TaxonomyPath("A", "B", "D"), t.keywordPath("foo bar"))
        assertNull("rules with a bad regex or path are skipped, not fatal", t.keywordPath("baz"))
    }

    @Test
    fun additionsKeepTheKeywordRules() {
        assertNotNull(taxonomy.adding(listOf(pets)).keywordPath("haferflocken"))
    }

    @Test
    fun everyKeywordRulePathExistsInTheTaxonomy() {
        val text = java.io.File("src/main/assets/category_taxonomy.json").readText()
        val rules = kotlinx.serialization.json.Json.parseToJsonElement(text).let { it as kotlinx.serialization.json.JsonObject }["keyword_rules"] as kotlinx.serialization.json.JsonArray
        assertEquals("all 18 rules are read", 18, rules.size)
        for (r in rules) {
            val path = TaxonomyPath.fromLabel((r as kotlinx.serialization.json.JsonObject)["path"]!!.let { (it as kotlinx.serialization.json.JsonPrimitive).content })!!
            assertTrue(path.label, taxonomy.contains(path))
        }
    }
}
