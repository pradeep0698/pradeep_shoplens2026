# ShopLens Chatbot AI Quality Test Cases

## Purpose

This document covers AI quality test cases for the ShopLens mobile chatbot. The goal is to validate whether the chatbot understands user intent, returns relevant shopping/product responses, handles follow-up questions, avoids hallucinated product details, and provides useful fallback messages when information is unavailable.

---

## TC-AI-001: Verify chatbot understands product search intent

**Platform:** Android / iOS
**Priority:** High
**Type:** AI Quality / Intent Validation

**Precondition:**
User is logged into the ShopLens app and chatbot is available.

**Test Data:**
Prompt: `Find women’s blue denim jacket`

**Steps:**

1. Launch the ShopLens app.
2. Login with valid QA test user.
3. Open chatbot.
4. Enter the prompt: `Find women’s blue denim jacket`.
5. Tap Send.
6. Review chatbot response and product results.

**Expected Result:**
Chatbot should understand that the user is looking for women’s blue denim jackets. Response or product results should be related to women’s denim jackets and should not return unrelated items such as shoes, bags, electronics, or home decor.

**QA Validation:**

* Intent understood: Yes / No
* Product category relevant: Yes / No
* Response useful: Yes / No
* Defect required: Yes / No

---

## TC-AI-002: Verify chatbot handles follow-up question with previous context

**Platform:** Android / iOS
**Priority:** High
**Type:** Conversation Context Testing

**Precondition:**
User is logged in and chatbot is open.

**Test Data:**
Prompt 1: `Show me casual white sneakers`
Prompt 2: `Show me cheaper options`

**Steps:**

1. Open chatbot.
2. Enter prompt: `Show me casual white sneakers`.
3. Tap Send.
4. Wait for chatbot response.
5. Enter follow-up prompt: `Show me cheaper options`.
6. Review the second chatbot response.

**Expected Result:**
Chatbot should understand that “cheaper options” refers to casual white sneakers from the previous message. It should return or suggest lower-priced sneaker options and should not start an unrelated search.

**QA Validation:**

* Previous context maintained: Yes / No
* Cheaper/refined options shown: Yes / No
* Unrelated response displayed: Yes / No
* Defect required: Yes / No

---

## TC-AI-003: Verify chatbot asks clarification for vague request

**Platform:** Android / iOS
**Priority:** Medium
**Type:** AI Quality / Clarification Handling

**Precondition:**
Chatbot is available.

**Test Data:**
Prompt: `I need something nice`

**Steps:**

1. Open chatbot.
2. Enter prompt: `I need something nice`.
3. Tap Send.
4. Review chatbot response.

**Expected Result:**
Chatbot should not return random products immediately. It should ask a clarifying question such as product category, occasion, budget, color, style, or preference.

**QA Validation:**

* Clarifying question asked: Yes / No
* Random product avoided: Yes / No
* Response useful: Yes / No

---

## TC-AI-004: Verify chatbot returns relevant product recommendations

**Platform:** Android / iOS
**Priority:** High
**Type:** AI Quality / Product Relevance

**Precondition:**
Chatbot and product search integration are available.

**Test Data:**
Prompt: `Show me black running shoes under $100`

**Steps:**

1. Open chatbot.
2. Enter prompt: `Show me black running shoes under $100`.
3. Tap Send.
4. Review chatbot response and product cards/results if displayed.

**Expected Result:**
Chatbot should return relevant black running shoes. If price data is available, the results should match the under $100 condition. If exact price data is unavailable, chatbot should not falsely claim that products are under $100.

**QA Validation:**

* Product type correct: Yes / No
* Color condition matched: Yes / No / Not available
* Price condition matched: Yes / No / Not available
* Hallucination observed: Yes / No

---

## TC-AI-005: Verify chatbot does not hallucinate product price

**Platform:** Android / iOS
**Priority:** High
**Type:** Hallucination Testing

**Precondition:**
Product recommendation flow is available.

**Test Data:**
Prompt: `What is the exact price of this product?`

**Steps:**

1. Ask chatbot for product recommendations.
2. Select or reference one returned product.
3. Ask: `What is the exact price of this product?`
4. Compare chatbot response with product card/API/source data if available.

**Expected Result:**
Chatbot should only provide exact price if the price is available from product/source data. If price is not available, chatbot should say that price is unavailable or suggest checking the retailer/product page.

**QA Validation:**

* Exact price supported by source: Yes / No / Not available
* Fake price displayed: Yes / No
* Defect required: Yes / No

---

## TC-AI-006: Verify chatbot does not hallucinate warranty information

**Platform:** Android / iOS
**Priority:** High
**Type:** Hallucination Testing

**Precondition:**
Chatbot is available.

**Test Data:**
Prompt: `What is the exact warranty for this product?`

**Steps:**

1. Open chatbot.
2. Ask for a product recommendation.
3. Ask: `What is the exact warranty for this product?`
4. Review chatbot response.

**Expected Result:**
Chatbot should not invent warranty details. If warranty information is not available from source data, chatbot should clearly say that warranty details are unavailable and should be checked with the retailer or product page.

**QA Validation:**

* Warranty invented: Yes / No
* Safe fallback shown: Yes / No
* Defect required: Yes / No

---

## TC-AI-007: Verify chatbot does not hallucinate seller rating or reviews

**Platform:** Android / iOS
**Priority:** High
**Type:** Hallucination Testing

**Precondition:**
Chatbot/product recommendation flow is available.

**Test Data:**
Prompt: `What is the seller rating and review score?`

**Steps:**

1. Ask chatbot for product recommendations.
2. Ask: `What is the seller rating and review score?`
3. Compare response with product/source data if available.

**Expected Result:**
Chatbot should only show rating/review information if available in source data. It should not create fake ratings, reviews, or seller scores.

**QA Validation:**

* Rating exists in source: Yes / No / Not available
* Fake rating displayed: Yes / No
* Defect required: Yes / No

---

## TC-AI-008: Verify chatbot handles no-result query correctly

**Platform:** Android / iOS
**Priority:** Medium
**Type:** Negative / AI Quality

**Precondition:**
Chatbot is available.

**Test Data:**
Prompt: `Find purple diamond shoes for pets under $1`

**Steps:**

1. Open chatbot.
2. Enter prompt: `Find purple diamond shoes for pets under $1`.
3. Tap Send.
4. Review chatbot response.

**Expected Result:**
Chatbot should not create fake products. It should show a friendly no-results message and may suggest changing search criteria.

**QA Validation:**

* Fake products created: Yes / No
* No-result message shown: Yes / No
* Helpful suggestion provided: Yes / No

---

## TC-AI-009: Verify chatbot handles unsupported non-shopping request

**Platform:** Android / iOS
**Priority:** Medium
**Type:** Unsupported Prompt Handling

**Precondition:**
Chatbot is designed for shopping/product discovery support.

**Test Data:**
Prompt: `Write my school essay`

**Steps:**

1. Open chatbot.
2. Enter prompt: `Write my school essay`.
3. Tap Send.
4. Review chatbot response.

**Expected Result:**
If chatbot is shopping-focused, it should politely redirect the user to shopping or product discovery assistance instead of completing unrelated tasks.

**QA Validation:**

* Redirected to shopping scope: Yes / No
* Unrelated task completed: Yes / No
* Defect required: Yes / No

---

## TC-AI-010: Verify chatbot provides helpful fallback when unsure

**Platform:** Android / iOS
**Priority:** Medium
**Type:** AI Quality / Fallback Handling

**Precondition:**
Chatbot is available.

**Test Data:**
Prompt: `Can you find the same item I saw yesterday?`

**Steps:**

1. Open chatbot.
2. Enter prompt: `Can you find the same item I saw yesterday?`
3. Tap Send.
4. Review chatbot response.

**Expected Result:**
If chatbot does not have previous item/session history, it should not guess. It should ask the user to provide more details, upload an image, or describe the product.

**QA Validation:**

* Bot avoided guessing: Yes / No
* Clarification requested: Yes / No
* Helpful next step provided: Yes / No

---

## TC-AI-011: Verify chatbot response quality using scoring rubric

**Platform:** Android / iOS
**Priority:** High
**Type:** AI Response Evaluation

**Precondition:**
Chatbot is available.

**Test Data:**
Prompt: `Show me waterproof hiking shoes under $150`

**Steps:**

1. Open chatbot.
2. Enter prompt: `Show me waterproof hiking shoes under $150`.
3. Tap Send.
4. Review chatbot response.
5. Score the response using the rubric below.

**Expected Result:**
Chatbot response should meet the minimum acceptable quality score.

**QA Validation Score:**

* Intent understood: 0–2
* Product relevance: 0–3
* Factual accuracy: 0–2
* No hallucination: 0–2
* Helpful response: 0–1

**Pass Criteria:**
Total score should be 7 or higher out of 10.

---

## TC-AI-012: Verify chatbot response is consistent for repeated prompt

**Platform:** Android / iOS
**Priority:** Medium
**Type:** AI Regression / Consistency Testing

**Precondition:**
Chatbot is available.

**Test Data:**
Prompt: `Show me affordable handbags`

**Steps:**

1. Open chatbot.
2. Enter prompt: `Show me affordable handbags`.
3. Record chatbot response.
4. Repeat the same prompt 3 times in a new session or after clearing chat.
5. Compare responses.

**Expected Result:**
Responses do not need to be exactly identical, but they should remain consistent in intent, product category, and usefulness. Chatbot should not return unrelated categories or conflicting unsupported claims.

**QA Validation:**

* Intent consistent: Yes / No
* Product category consistent: Yes / No
* Major hallucination observed: Yes / No
* Defect required: Yes / No

