
# ShopLens Chatbot Functional Test Cases

## Purpose

This document covers functional test cases for the ShopLens mobile chatbot on Android and iOS. The goal is to verify that the chatbot opens correctly, accepts user input, displays user messages, returns chatbot responses, handles basic validations, and supports normal mobile chat behavior without UI or functional issues.

---

## TC-FUNC-001: Verify chatbot entry point is visible on Android

**Platform:** Android
**Priority:** High
**Type:** Functional

**Precondition:**
User is logged into the ShopLens Android app.

**Test Data:**
Valid QA test user account.

**Steps:**

1. Launch the ShopLens Android app.
2. Login with valid credentials.
3. Navigate to the screen where chatbot is available.
4. Verify chatbot icon/button is displayed.

**Expected Result:**
Chatbot icon/button should be visible and accessible on the Android app.

**QA Validation:**

* Chatbot icon visible: Yes / No
* Icon/button clickable: Yes / No
* UI overlap observed: Yes / No
* Defect required: Yes / No

---

## TC-FUNC-002: Verify chatbot entry point is visible on iOS

**Platform:** iOS
**Priority:** High
**Type:** Functional

**Precondition:**
User is logged into the ShopLens iOS app.

**Test Data:**
Valid QA test user account.

**Steps:**

1. Launch the ShopLens iOS app.
2. Login with valid credentials.
3. Navigate to the screen where chatbot is available.
4. Verify chatbot icon/button is displayed.

**Expected Result:**
Chatbot icon/button should be visible and accessible on the iOS app.

**QA Validation:**

* Chatbot icon visible: Yes / No
* Icon/button clickable: Yes / No
* UI overlap observed: Yes / No
* Defect required: Yes / No

---

## TC-FUNC-003: Verify chatbot opens successfully on Android

**Platform:** Android
**Priority:** High
**Type:** Functional

**Precondition:**
User is logged into the ShopLens Android app and chatbot entry point is visible.

**Steps:**

1. Launch the ShopLens Android app.
2. Tap the chatbot icon/button.
3. Observe chatbot window.

**Expected Result:**
Chatbot window should open successfully. Greeting message, input field, and send button should be visible.

**QA Validation:**

* Chatbot window opened: Yes / No
* Greeting message visible: Yes / No
* Input field visible: Yes / No
* Send button visible: Yes / No
* App crash observed: Yes / No

---

## TC-FUNC-004: Verify chatbot opens successfully on iOS

**Platform:** iOS
**Priority:** High
**Type:** Functional

**Precondition:**
User is logged into the ShopLens iOS app and chatbot entry point is visible.

**Steps:**

1. Launch the ShopLens iOS app.
2. Tap the chatbot icon/button.
3. Observe chatbot window.

**Expected Result:**
Chatbot window should open successfully. Greeting message, input field, and send button should be visible.

**QA Validation:**

* Chatbot window opened: Yes / No
* Greeting message visible: Yes / No
* Input field visible: Yes / No
* Send button visible: Yes / No
* App crash observed: Yes / No

---

## TC-FUNC-005: Verify user can type a chatbot message

**Platform:** Android / iOS
**Priority:** High
**Type:** Functional

**Precondition:**
Chatbot is open.

**Test Data:**
Prompt: `Show me black running shoes under $100`

**Steps:**

1. Open chatbot.
2. Tap inside the chatbot input field.
3. Enter the prompt: `Show me black running shoes under $100`.
4. Verify text appears correctly in the input field.

**Expected Result:**
User should be able to type the message in the chatbot input field without keyboard, cursor, or text display issue.

**QA Validation:**

* Keyboard opened properly: Yes / No
* Text entered correctly: Yes / No
* Input field visible while typing: Yes / No
* Defect required: Yes / No

---

## TC-FUNC-006: Verify user can send a chatbot message

**Platform:** Android / iOS
**Priority:** High
**Type:** Functional

**Precondition:**
Chatbot is open and user has entered a valid message.

**Test Data:**
Prompt: `Show me affordable handbags`

**Steps:**

1. Open chatbot.
2. Enter the prompt: `Show me affordable handbags`.
3. Tap Send.
4. Observe the chat thread.

**Expected Result:**
User message should be submitted and displayed in the chat thread.

**QA Validation:**

* Message submitted successfully: Yes / No
* User message visible in chat thread: Yes / No
* Duplicate message created: Yes / No
* Defect required: Yes / No

---

## TC-FUNC-007: Verify chatbot loading indicator appears after sending message

**Platform:** Android / iOS
**Priority:** Medium
**Type:** Functional / UI Feedback

**Precondition:**
Chatbot is open.

**Test Data:**
Prompt: `Find women’s blue denim jacket`

**Steps:**

1. Open chatbot.
2. Enter the prompt: `Find women’s blue denim jacket`.
3. Tap Send.
4. Observe chatbot behavior before response appears.

**Expected Result:**
A loading indicator, typing indicator, spinner, or similar progress state should appear while chatbot response is being generated.

**QA Validation:**

* Loading/typing indicator visible: Yes / No
* Indicator disappears after response: Yes / No
* App stuck in loading state: Yes / No

---

## TC-FUNC-008: Verify chatbot response is displayed

**Platform:** Android / iOS
**Priority:** High
**Type:** Functional

**Precondition:**
Chatbot is open and AI service is available.

**Test Data:**
Prompt: `Show me casual white sneakers`

**Steps:**

1. Open chatbot.
2. Enter the prompt: `Show me casual white sneakers`.
3. Tap Send.
4. Wait for chatbot response.

**Expected Result:**
Chatbot should return a visible response. Response should not be blank or unreadable.

**QA Validation:**

* Bot response visible: Yes / No
* Response text readable: Yes / No
* Blank response displayed: Yes / No
* Defect required: Yes / No

---

## TC-FUNC-009: Verify empty message cannot be submitted

**Platform:** Android / iOS
**Priority:** Medium
**Type:** Functional / Negative

**Precondition:**
Chatbot is open.

**Test Data:**
Blank input field.

**Steps:**

1. Open chatbot.
2. Leave the message input field blank.
3. Tap Send.

**Expected Result:**
Blank message should not be submitted. Send button should be disabled or a validation message should be displayed.

**QA Validation:**

* Empty message blocked: Yes / No
* Validation message displayed: Yes / No / Not applicable
* Blank message appears in chat thread: Yes / No

---

## TC-FUNC-010: Verify chatbot handles long user message

**Platform:** Android / iOS
**Priority:** Medium
**Type:** Functional / Boundary Testing

**Precondition:**
Chatbot is open.

**Test Data:**
Prompt: `I am looking for a comfortable, lightweight, waterproof, budget-friendly, black running shoe for women under $100 that can be used for walking, gym, and casual outdoor activities.`

**Steps:**

1. Open chatbot.
2. Enter the long prompt.
3. Tap Send.
4. Observe app behavior and chatbot response.

**Expected Result:**
App should accept the message or show a clear input length validation message. Chatbot should not crash or freeze.

**QA Validation:**

* Long message accepted: Yes / No
* Validation shown if too long: Yes / No / Not applicable
* App crash/freeze observed: Yes / No

---

## TC-FUNC-011: Verify chatbot can be closed

**Platform:** Android / iOS
**Priority:** Medium
**Type:** Functional

**Precondition:**
Chatbot is open.

**Steps:**

1. Open chatbot.
2. Tap close, back, X, or minimize option based on design.
3. Observe app screen.

**Expected Result:**
Chatbot should close or minimize correctly and user should return to previous app screen without crash.

**QA Validation:**

* Chatbot closed/minimized: Yes / No
* Previous screen displayed: Yes / No
* App crash observed: Yes / No

---

## TC-FUNC-012: Verify chatbot can be reopened after closing

**Platform:** Android / iOS
**Priority:** Medium
**Type:** Functional / Regression

**Precondition:**
Chatbot was opened and closed.

**Steps:**

1. Open chatbot.
2. Close chatbot.
3. Reopen chatbot.
4. Observe chatbot window.

**Expected Result:**
Chatbot should reopen successfully without UI issue or app crash.

**QA Validation:**

* Chatbot reopened successfully: Yes / No
* Previous state behavior matches requirement: Yes / No / Not defined
* App crash observed: Yes / No

---

## TC-FUNC-013: Verify chatbot input clears after sending message

**Platform:** Android / iOS
**Priority:** Medium
**Type:** Functional

**Precondition:**
Chatbot is open.

**Test Data:**
Prompt: `Show me summer dresses`

**Steps:**

1. Open chatbot.
2. Enter prompt: `Show me summer dresses`.
3. Tap Send.
4. Observe input field after message is submitted.

**Expected Result:**
Input field should clear after the message is sent.

**QA Validation:**

* Input cleared after send: Yes / No
* Same message remains in input: Yes / No
* Defect required: Yes / No

---

## TC-FUNC-014: Verify chatbot supports multiple messages in same session

**Platform:** Android / iOS
**Priority:** High
**Type:** Functional / Conversation Flow

**Precondition:**
Chatbot is open.

**Test Data:**
Prompt 1: `Show me casual shoes`
Prompt 2: `Show me handbags`
Prompt 3: `Show me jackets`

**Steps:**

1. Open chatbot.
2. Send Prompt 1.
3. Wait for response.
4. Send Prompt 2.
5. Wait for response.
6. Send Prompt 3.
7. Review chat thread.

**Expected Result:**
Chatbot should handle multiple messages in the same session. Messages and responses should display in correct order.

**QA Validation:**

* All messages submitted: Yes / No
* All responses displayed: Yes / No
* Message order correct: Yes / No
* App crash/freeze observed: Yes / No

---

## TC-FUNC-015: Verify chatbot handles unsupported request gracefully

**Platform:** Android / iOS
**Priority:** Medium
**Type:** Functional / Negative

**Precondition:**
Chatbot is available.

**Test Data:**
Prompt: `Write my school essay`

**Steps:**

1. Open chatbot.
2. Enter prompt: `Write my school essay`.
3. Tap Send.
4. Review response.

**Expected Result:**
If chatbot is designed for shopping/product discovery, it should politely redirect user to shopping-related help and should not crash or return blank response.

**QA Validation:**

* Graceful response displayed: Yes / No
* Blank response displayed: Yes / No
* Unrelated task completed: Yes / No
* Defect required: Yes / No

---

## TC-FUNC-016: Verify chatbot handles no internet connection

**Platform:** Android / iOS
**Priority:** High
**Type:** Functional / Error Handling

**Precondition:**
Chatbot is open.

**Test Data:**
Prompt: `Show me black shoes`

**Steps:**

1. Open chatbot.
2. Turn off Wi-Fi and mobile data.
3. Enter prompt: `Show me black shoes`.
4. Tap Send.
5. Observe app behavior.

**Expected Result:**
App should show a clear network error or retry message. App should not crash or keep loading forever.

**QA Validation:**

* Network error shown: Yes / No
* Retry option shown: Yes / No / Not applicable
* Infinite loading observed: Yes / No
* App crash observed: Yes / No

---

## TC-FUNC-017: Verify chatbot handles slow response

**Platform:** Android / iOS
**Priority:** Medium
**Type:** Functional / Error Handling

**Precondition:**
Chatbot service is available but response may be delayed.

**Test Data:**
Prompt: `Show me best laptops, bags, shoes, jackets, and watches under $50`

**Steps:**

1. Open chatbot.
2. Enter the prompt.
3. Tap Send.
4. Observe loading behavior and final response.

**Expected Result:**
Chatbot should either return a response within acceptable time or show clear timeout/retry message. App should not freeze.

**QA Validation:**

* Response received: Yes / No
* Timeout/retry message shown: Yes / No / Not applicable
* App freeze observed: Yes / No

---

## TC-FUNC-018: Verify chatbot message text is readable

**Platform:** Android / iOS
**Priority:** Medium
**Type:** UI Functional

**Precondition:**
Chatbot has at least one user message and one bot response.

**Steps:**

1. Open chatbot.
2. Send a valid prompt.
3. Review user message and bot response text.

**Expected Result:**
Message text should be readable with proper font size, spacing, contrast, and alignment.

**QA Validation:**

* User message readable: Yes / No
* Bot response readable: Yes / No
* Text overlap/truncation observed: Yes / No

---

## TC-FUNC-019: Verify chatbot scroll behavior

**Platform:** Android / iOS
**Priority:** Medium
**Type:** Functional / UI

**Precondition:**
Chatbot has multiple messages.

**Steps:**

1. Open chatbot.
2. Send multiple messages until chat thread becomes scrollable.
3. Scroll up and down through messages.

**Expected Result:**
User should be able to scroll through chatbot conversation smoothly. Latest response should be accessible.

**QA Validation:**

* Scroll works smoothly: Yes / No
* Messages visible after scrolling: Yes / No
* Chat jumps unexpectedly: Yes / No

---

## TC-FUNC-020: Verify chatbot works after app restart

**Platform:** Android / iOS
**Priority:** Medium
**Type:** Functional / Regression

**Precondition:**
Chatbot is available.

**Steps:**

1. Launch app and open chatbot.
2. Send a valid prompt.
3. Close the app completely.
4. Relaunch app.
5. Open chatbot again.

**Expected Result:**
App should reopen successfully and chatbot should behave as per session requirement. It should not crash or show corrupted conversation state.

**QA Validation:**

* App reopened successfully: Yes / No
* Chatbot available after restart: Yes / No
* Session behavior correct: Yes / No / Not defined
* App crash observed: Yes / No
